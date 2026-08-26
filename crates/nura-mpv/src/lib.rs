use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::path::Path;
use std::ptr;
use std::sync::{Arc, Mutex};

use libloading::Library;
use nura_domain::{MediaItem, Track, TrackKind};
use nura_player_core::{EngineError, EngineEvent, PlaybackEngine};
use thiserror::Error;

type MpvHandle = c_void;
type MpvRenderContext = c_void;

#[repr(C)]
struct MpvEvent {
    event_id: u32,
    error: c_int,
    reply_userdata: u64,
    data: *mut c_void,
}

#[repr(C)]
struct MpvRenderParam {
    param_type: c_int,
    data: *mut c_void,
}

#[repr(C)]
struct MpvOpenGlInitParams {
    get_proc_address: Option<unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_void>,
    get_proc_address_ctx: *mut c_void,
}

#[repr(C)]
struct MpvOpenGlFbo {
    fbo: i32,
    w: i32,
    h: i32,
    internal_format: i32,
}

const MPV_FORMAT_DOUBLE: c_int = 5;
const MPV_EVENT_NONE: u32 = 0;
const MPV_EVENT_SHUTDOWN: u32 = 1;
const MPV_EVENT_END_FILE: u32 = 7;
const MPV_EVENT_FILE_LOADED: u32 = 8;
const MPV_EVENT_PROPERTY_CHANGE: u32 = 22;
const MPV_RENDER_PARAM_API_TYPE: c_int = 1;
const MPV_RENDER_PARAM_OPENGL_INIT_PARAMS: c_int = 2;
const MPV_RENDER_PARAM_OPENGL_FBO: c_int = 3;
const MPV_RENDER_PARAM_FLIP_Y: c_int = 4;

struct MpvApi {
    _library: Library,
    create: unsafe extern "C" fn() -> *mut MpvHandle,
    initialize: unsafe extern "C" fn(*mut MpvHandle) -> c_int,
    terminate_destroy: unsafe extern "C" fn(*mut MpvHandle),
    command: unsafe extern "C" fn(*mut MpvHandle, *const *const c_char) -> c_int,
    set_option_string: unsafe extern "C" fn(*mut MpvHandle, *const c_char, *const c_char) -> c_int,
    get_property: unsafe extern "C" fn(*mut MpvHandle, *const c_char, c_int, *mut c_void) -> c_int,
    get_property_string: unsafe extern "C" fn(*mut MpvHandle, *const c_char) -> *mut c_char,
    free: unsafe extern "C" fn(*mut c_void),
    wait_event: unsafe extern "C" fn(*mut MpvHandle, f64) -> *mut MpvEvent,
    render_create: unsafe extern "C" fn(
        *mut *mut MpvRenderContext,
        *mut MpvHandle,
        *const MpvRenderParam,
    ) -> c_int,
    render_render: unsafe extern "C" fn(*mut MpvRenderContext, *const MpvRenderParam) -> c_int,
    render_free: unsafe extern "C" fn(*mut MpvRenderContext),
}

impl MpvApi {
    unsafe fn load_symbol<T: Copy>(library: &Library, name: &[u8]) -> Result<T, MpvError> {
        Ok(*library.get::<T>(name).map_err(|error| MpvError::Symbol {
            name: String::from_utf8_lossy(name)
                .trim_end_matches('\0')
                .to_owned(),
            error: error.to_string(),
        })?)
    }

    fn load() -> Result<Self, MpvError> {
        let candidates = [
            std::env::var("NURA_MPV_LIBRARY").unwrap_or_default(),
            "/opt/homebrew/lib/libmpv.2.dylib".to_owned(),
            "/usr/local/lib/libmpv.2.dylib".to_owned(),
            "libmpv.2.dylib".to_owned(),
        ];
        let mut last_error = String::from("no candidate path could be loaded");
        for candidate in candidates.into_iter().filter(|value| !value.is_empty()) {
            let library = unsafe { Library::new(&candidate) };
            let Ok(library) = library else {
                last_error = format!("could not load {candidate}");
                continue;
            };
            let loaded: Result<Self, MpvError> = unsafe {
                Ok(Self {
                    create: Self::load_symbol(&library, b"mpv_create\0")?,
                    initialize: Self::load_symbol(&library, b"mpv_initialize\0")?,
                    terminate_destroy: Self::load_symbol(&library, b"mpv_terminate_destroy\0")?,
                    command: Self::load_symbol(&library, b"mpv_command\0")?,
                    set_option_string: Self::load_symbol(&library, b"mpv_set_option_string\0")?,
                    get_property: Self::load_symbol(&library, b"mpv_get_property\0")?,
                    get_property_string: Self::load_symbol(&library, b"mpv_get_property_string\0")?,
                    free: Self::load_symbol(&library, b"mpv_free\0")?,
                    wait_event: Self::load_symbol(&library, b"mpv_wait_event\0")?,
                    render_create: Self::load_symbol(&library, b"mpv_render_context_create\0")?,
                    render_render: Self::load_symbol(&library, b"mpv_render_context_render\0")?,
                    render_free: Self::load_symbol(&library, b"mpv_render_context_free\0")?,
                    _library: library,
                })
            };
            if let Ok(api) = loaded {
                return Ok(api);
            }
            last_error = format!("{candidate} is missing required libmpv symbols");
        }
        Err(MpvError::Unavailable(last_error))
    }
}

pub struct MpvEngine {
    api: MpvApi,
    handle: *mut MpvHandle,
    render_context: *mut MpvRenderContext,
    pending_start: f64,
    last_position: f64,
}

unsafe impl Send for MpvEngine {}

impl MpvEngine {
    pub fn new() -> Result<Self, MpvError> {
        let api = MpvApi::load()?;
        let handle = unsafe { (api.create)() };
        if handle.is_null() {
            return Err(MpvError::Create);
        }
        for (key, value) in [
            ("vo", "libmpv"),
            // The initial OpenGL render path does not provide hardware-decoder
            // interop resources, so keep decoded frames in a software surface.
            ("hwdec", "no"),
            ("idle", "yes"),
            ("audio-display", "no"),
            ("keep-open", "yes"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            // Keep libmpv's metadata-driven autorotation enabled. `no` would
            // suppress rotation metadata from phone/camera videos.
            ("video-rotate", "0"),
        ] {
            let key = CString::new(key).unwrap();
            let value = CString::new(value).unwrap();
            let result = unsafe { (api.set_option_string)(handle, key.as_ptr(), value.as_ptr()) };
            if result < 0 {
                unsafe { (api.terminate_destroy)(handle) };
                return Err(MpvError::Call(result));
            }
        }
        let result = unsafe { (api.initialize)(handle) };
        if result < 0 {
            unsafe { (api.terminate_destroy)(handle) };
            return Err(MpvError::Call(result));
        }
        Ok(Self {
            api,
            handle,
            render_context: ptr::null_mut(),
            pending_start: 0.0,
            last_position: 0.0,
        })
    }

    fn command(&self, values: &[&str]) -> Result<(), EngineError> {
        let strings: Vec<CString> = values
            .iter()
            .map(|value| CString::new(*value).unwrap())
            .collect();
        let mut pointers: Vec<*const c_char> = strings.iter().map(|value| value.as_ptr()).collect();
        pointers.push(ptr::null());
        let result = unsafe { (self.api.command)(self.handle, pointers.as_ptr()) };
        if result < 0 {
            return Err(EngineError::Message(format!(
                "libmpv command failed ({result})"
            )));
        }
        Ok(())
    }

    fn property_string(&self, name: &str) -> Option<String> {
        let name = CString::new(name).ok()?;
        let value = unsafe { (self.api.get_property_string)(self.handle, name.as_ptr()) };
        if value.is_null() {
            return None;
        }
        let string = unsafe { CStr::from_ptr(value).to_string_lossy().into_owned() };
        unsafe { (self.api.free)(value.cast()) };
        Some(string)
    }

    fn duration(&self) -> Option<f64> {
        let name = CString::new("duration").unwrap();
        let mut value = 0.0;
        let result = unsafe {
            (self.api.get_property)(
                self.handle,
                name.as_ptr(),
                MPV_FORMAT_DOUBLE,
                (&mut value as *mut f64).cast(),
            )
        };
        (result >= 0).then_some(value)
    }

    fn tracks(&self) -> Vec<Track> {
        let count = self
            .property_string("track-list/count")
            .and_then(|value| value.parse::<i64>().ok())
            .unwrap_or(0);
        (0..count)
            .filter_map(|index| {
                let prefix = format!("track-list/{index}");
                let kind = match self.property_string(&format!("{prefix}/type"))?.as_str() {
                    "audio" => TrackKind::Audio,
                    "sub" => TrackKind::Subtitle,
                    _ => return None,
                };
                let id = self
                    .property_string(&format!("{prefix}/id"))?
                    .parse()
                    .ok()?;
                Some(Track {
                    id,
                    kind,
                    title: self.property_string(&format!("{prefix}/title")),
                    language: self.property_string(&format!("{prefix}/lang")),
                    external: self
                        .property_string(&format!("{prefix}/external"))
                        .as_deref()
                        == Some("yes"),
                    selected: self
                        .property_string(&format!("{prefix}/selected"))
                        .as_deref()
                        == Some("yes"),
                })
            })
            .collect()
    }

    pub fn attach_opengl_context(&mut self) -> Result<(), EngineError> {
        if !self.render_context.is_null() {
            return Ok(());
        }
        unsafe extern "C" fn get_proc_address(_: *mut c_void, name: *const c_char) -> *mut c_void {
            libc::dlsym(libc::RTLD_DEFAULT, name)
        }
        let api_type = CString::new("opengl").unwrap();
        let mut init = MpvOpenGlInitParams {
            get_proc_address: Some(get_proc_address),
            get_proc_address_ctx: ptr::null_mut(),
        };
        let params = [
            MpvRenderParam {
                param_type: MPV_RENDER_PARAM_API_TYPE,
                data: api_type.as_ptr().cast_mut().cast(),
            },
            MpvRenderParam {
                param_type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                data: (&mut init as *mut MpvOpenGlInitParams).cast(),
            },
            MpvRenderParam {
                param_type: 0,
                data: ptr::null_mut(),
            },
        ];
        let result = unsafe {
            (self.api.render_create)(&mut self.render_context, self.handle, params.as_ptr())
        };
        if result < 0 {
            return Err(EngineError::Message(format!(
                "libmpv render context failed ({result})"
            )));
        }
        Ok(())
    }

    pub fn render_opengl(&mut self, fbo: i32, width: i32, height: i32) -> Result<(), EngineError> {
        if self.render_context.is_null() {
            return Err(EngineError::Message(
                "libmpv render context is not initialized".to_owned(),
            ));
        }
        let mut framebuffer = MpvOpenGlFbo {
            fbo,
            w: width,
            h: height,
            internal_format: 0,
        };
        // NSOpenGLView uses the bottom-left OpenGL origin. libmpv's Cocoa
        // render path expects the target to be flipped into that coordinate
        // system; this also keeps display-matrix rotation directions correct.
        let mut flip_y = 1i32;
        let params = [
            MpvRenderParam {
                param_type: MPV_RENDER_PARAM_OPENGL_FBO,
                data: (&mut framebuffer as *mut MpvOpenGlFbo).cast(),
            },
            MpvRenderParam {
                param_type: MPV_RENDER_PARAM_FLIP_Y,
                data: (&mut flip_y as *mut i32).cast(),
            },
            MpvRenderParam {
                param_type: 0,
                data: ptr::null_mut(),
            },
        ];
        let result = unsafe { (self.api.render_render)(self.render_context, params.as_ptr()) };
        if result < 0 {
            return Err(EngineError::Message(format!(
                "libmpv render failed ({result})"
            )));
        }
        Ok(())
    }
}

impl Drop for MpvEngine {
    fn drop(&mut self) {
        unsafe {
            if !self.render_context.is_null() {
                (self.api.render_free)(self.render_context);
            }
            if !self.handle.is_null() {
                (self.api.terminate_destroy)(self.handle);
            }
        }
    }
}

impl PlaybackEngine for MpvEngine {
    fn load(&mut self, item: &MediaItem, start_position_seconds: f64) -> Result<(), EngineError> {
        self.pending_start = start_position_seconds;
        self.command(&["loadfile", &item.path.to_string_lossy(), "replace"])
    }
    fn play(&mut self) -> Result<(), EngineError> {
        self.command(&["set", "pause", "no"])
    }
    fn pause(&mut self) -> Result<(), EngineError> {
        self.command(&["set", "pause", "yes"])
    }
    fn seek(&mut self, position_seconds: f64) -> Result<(), EngineError> {
        self.command(&["seek", &position_seconds.to_string(), "absolute", "exact"])
    }
    fn set_volume(&mut self, volume: f64) -> Result<(), EngineError> {
        self.command(&["set", "volume", &volume.to_string()])
    }
    fn set_mute(&mut self, muted: bool) -> Result<(), EngineError> {
        self.command(&["set", "mute", if muted { "yes" } else { "no" }])
    }
    fn select_track(&mut self, kind: TrackKind, track_id: Option<i64>) -> Result<(), EngineError> {
        let property = if kind == TrackKind::Audio {
            "aid"
        } else {
            "sid"
        };
        self.command(&[
            "set",
            property,
            &track_id
                .map(|id| id.to_string())
                .unwrap_or_else(|| "no".to_owned()),
        ])
    }
    fn add_external_subtitle(&mut self, path: &Path) -> Result<(), EngineError> {
        self.command(&["sub-add", &path.to_string_lossy(), "select"])
    }
    fn stop(&mut self) -> Result<(), EngineError> {
        self.command(&["stop"])
    }
    fn drain_events(&mut self) -> Result<Vec<EngineEvent>, EngineError> {
        let mut events = Vec::new();
        loop {
            let event = unsafe { &*(self.api.wait_event)(self.handle, 0.0) };
            if event.event_id == MPV_EVENT_NONE {
                break;
            }
            match event.event_id {
                MPV_EVENT_FILE_LOADED => {
                    if self.pending_start > 0.0 {
                        let position = self.pending_start;
                        self.command(&["seek", &position.to_string(), "absolute", "exact"])?;
                    }
                    events.push(EngineEvent::FileLoaded {
                        duration_seconds: self.duration(),
                        tracks: self.tracks(),
                    });
                }
                MPV_EVENT_END_FILE => events.push(EngineEvent::Ended),
                MPV_EVENT_SHUTDOWN => events.push(EngineEvent::Failed(
                    "libmpv shut down unexpectedly".to_owned(),
                )),
                MPV_EVENT_PROPERTY_CHANGE => {}
                _ => {}
            }
        }
        if let Some(position) = self
            .property_string("time-pos")
            .and_then(|value| value.parse::<f64>().ok())
        {
            if (position - self.last_position).abs() >= 0.25 {
                self.last_position = position;
                events.push(EngineEvent::PositionChanged(position));
            }
        }
        if let Some(paused) = self.property_string("pause") {
            events.push(EngineEvent::Paused(paused == "yes"));
        }
        Ok(events)
    }
}

#[derive(Clone)]
pub struct SharedMpvEngine(pub Arc<Mutex<MpvEngine>>);

impl PlaybackEngine for SharedMpvEngine {
    fn load(&mut self, item: &MediaItem, start: f64) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .load(item, start)
    }
    fn play(&mut self) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .play()
    }
    fn pause(&mut self) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .pause()
    }
    fn seek(&mut self, position: f64) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .seek(position)
    }
    fn set_volume(&mut self, volume: f64) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_volume(volume)
    }
    fn set_mute(&mut self, muted: bool) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_mute(muted)
    }
    fn select_track(&mut self, kind: TrackKind, id: Option<i64>) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .select_track(kind, id)
    }
    fn add_external_subtitle(&mut self, path: &Path) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .add_external_subtitle(path)
    }
    fn stop(&mut self) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .stop()
    }
    fn drain_events(&mut self) -> Result<Vec<EngineEvent>, EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .drain_events()
    }
}

#[derive(Debug, Error)]
pub enum MpvError {
    #[error("libmpv is unavailable: {0}")]
    Unavailable(String),
    #[error("could not create the libmpv handle")]
    Create,
    #[error("libmpv call failed with code {0}")]
    Call(c_int),
    #[error("missing libmpv symbol {name}: {error}")]
    Symbol { name: String, error: String },
}
