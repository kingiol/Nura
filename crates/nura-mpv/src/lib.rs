use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::{Arc, Mutex};

use libloading::Library;
use nura_domain::{AudioDevice, MediaItem, Track, TrackKind};
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

fn bundled_mpv_library(executable: &Path) -> Option<PathBuf> {
    let macos = executable.parent()?;
    let contents = macos.parent()?;
    let app = contents.parent()?;

    (macos.file_name()?.to_str() == Some("MacOS")
        && contents.file_name()?.to_str() == Some("Contents")
        && app.extension()?.to_str() == Some("app"))
    .then(|| contents.join("Frameworks/libmpv.2.dylib"))
}

fn mpv_library_candidates(
    override_path: Option<&Path>,
    executable: Option<&Path>,
    release_build: bool,
) -> Vec<PathBuf> {
    let mut candidates = Vec::new();

    if let Some(path) = override_path {
        candidates.push(path.to_owned());
    }

    if let Some(bundled) = executable.and_then(bundled_mpv_library) {
        candidates.push(bundled);
        if release_build {
            return candidates;
        }
    }

    candidates.extend([
        PathBuf::from("/opt/homebrew/lib/libmpv.2.dylib"),
        PathBuf::from("/usr/local/lib/libmpv.2.dylib"),
        PathBuf::from("libmpv.2.dylib"),
    ]);
    candidates
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
        let override_path = std::env::var_os("NURA_MPV_LIBRARY").map(PathBuf::from);
        let executable = std::env::current_exe().ok();
        let candidates = mpv_library_candidates(
            override_path.as_deref(),
            executable.as_deref(),
            !cfg!(debug_assertions),
        );
        let mut last_error = String::from("no candidate path could be loaded");
        for candidate in candidates {
            let library = unsafe { Library::new(&candidate) };
            let Ok(library) = library else {
                last_error = format!("could not load {}", candidate.display());
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
            last_error = format!("{} is missing required libmpv symbols", candidate.display());
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
    last_buffering: Option<f64>,
    last_video_size: (Option<u32>, Option<u32>),
    last_speed: f64,
    last_tracks: Vec<Track>,
    last_audio_devices: Vec<AudioDevice>,
}

unsafe impl Send for MpvEngine {}

impl MpvEngine {
    fn ytdl_path() -> Option<String> {
        let mut candidates = Vec::new();
        if let Ok(path) = std::env::var("NURA_YTDL_PATH") {
            candidates.push(path);
        }
        if let Ok(executable) = std::env::current_exe() {
            if let Some(resources) = executable.parent().and_then(|path| path.parent()) {
                candidates.push(
                    resources
                        .join("Resources/bin/yt-dlp")
                        .to_string_lossy()
                        .into_owned(),
                );
            }
        }
        candidates.extend([
            "/opt/homebrew/bin/yt-dlp".to_owned(),
            "/usr/local/bin/yt-dlp".to_owned(),
        ]);
        candidates
            .into_iter()
            .find(|path| Path::new(path).is_file())
    }

    pub fn new() -> Result<Self, MpvError> {
        let api = MpvApi::load()?;
        let handle = unsafe { (api.create)() };
        if handle.is_null() {
            return Err(MpvError::Create);
        }
        let mut options = vec![
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
            // Keep online media enabled; the bundled ytdl hook resolves public
            // YouTube/Bilibili URLs before mpv opens the resulting streams.
            ("ytdl", "yes"),
            ("ytdl-format", "bestvideo+bestaudio/best"),
        ];
        if let Some(path) = Self::ytdl_path() {
            let value: &'static str =
                Box::leak(format!("ytdl_hook-ytdl_path={path}").into_boxed_str());
            options.push(("script-opts", value));
        }
        for (key, value) in options {
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
            last_buffering: None,
            last_video_size: (None, None),
            last_speed: 1.0,
            last_tracks: Vec::new(),
            last_audio_devices: Vec::new(),
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

    fn video_display_size(&self) -> (Option<u32>, Option<u32>) {
        let dimension = |name: &str| {
            self.property_string(name)
                .and_then(|value| value.parse::<f64>().ok())
                .filter(|value| value.is_finite() && *value > 0.0 && *value <= u32::MAX as f64)
                .map(|value| value.round() as u32)
        };
        (
            dimension("video-out-params/dw"),
            dimension("video-out-params/dh"),
        )
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
                    "video" => TrackKind::Video,
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

    fn chapters(&self) -> Vec<nura_domain::Chapter> {
        let count = self
            .property_string("chapter-list/count")
            .and_then(|value| value.parse::<i64>().ok())
            .unwrap_or(0);
        (0..count)
            .filter_map(|index| {
                let prefix = format!("chapter-list/{index}");
                let start_seconds = self
                    .property_string(&format!("{prefix}/time"))
                    .and_then(|value| value.parse::<f64>().ok())?;
                let title = self
                    .property_string(&format!("{prefix}/title"))
                    .filter(|value| !value.is_empty())
                    .unwrap_or_else(|| format!("Chapter {}", index + 1));
                Some(nura_domain::Chapter {
                    id: index,
                    title,
                    start_seconds,
                })
            })
            .collect()
    }

    fn audio_devices(&self) -> Vec<AudioDevice> {
        let selected_id = self.property_string("audio-device");
        let count = self
            .property_string("audio-device-list/count")
            .and_then(|value| value.parse::<i64>().ok())
            .unwrap_or(0);
        (0..count)
            .filter_map(|index| {
                let prefix = format!("audio-device-list/{index}");
                let id = self.property_string(&format!("{prefix}/name"))?;
                let name = self
                    .property_string(&format!("{prefix}/description"))
                    .filter(|value| !value.is_empty())
                    .unwrap_or_else(|| id.clone());
                Some(AudioDevice {
                    selected: selected_id.as_deref() == Some(id.as_str()),
                    id,
                    name,
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
        self.command(&["loadfile", &item.locator(), "replace"])
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
    fn seek_relative(&mut self, offset_seconds: f64) -> Result<(), EngineError> {
        self.command(&["seek", &offset_seconds.to_string(), "relative", "exact"])
    }
    fn frame_step(&mut self) -> Result<(), EngineError> {
        self.command(&["frame-step"])
    }
    fn set_volume(&mut self, volume: f64) -> Result<(), EngineError> {
        self.command(&["set", "volume", &volume.to_string()])
    }
    fn set_mute(&mut self, muted: bool) -> Result<(), EngineError> {
        self.command(&["set", "mute", if muted { "yes" } else { "no" }])
    }
    fn set_speed(&mut self, speed: f64) -> Result<(), EngineError> {
        self.command(&["set", "speed", &speed.to_string()])
    }
    fn set_loop(&mut self, enabled: bool) -> Result<(), EngineError> {
        self.command(&["set", "loop-file", if enabled { "yes" } else { "no" }])
    }
    fn set_ab_loop(&mut self, start: Option<f64>, end: Option<f64>) -> Result<(), EngineError> {
        self.command(&[
            "set",
            "ab-loop-a",
            &start
                .map(|value| value.to_string())
                .unwrap_or_else(|| "no".to_owned()),
        ])?;
        self.command(&[
            "set",
            "ab-loop-b",
            &end.map(|value| value.to_string())
                .unwrap_or_else(|| "no".to_owned()),
        ])
    }
    fn set_subtitle_delay(&mut self, delay_seconds: f64) -> Result<(), EngineError> {
        self.command(&["set", "sub-delay", &delay_seconds.to_string()])
    }
    fn set_audio_delay(&mut self, delay_seconds: f64) -> Result<(), EngineError> {
        self.command(&["set", "audio-delay", &delay_seconds.to_string()])
    }
    fn set_audio_device(&mut self, device_id: &str) -> Result<(), EngineError> {
        self.command(&["set", "audio-device", device_id])
    }
    fn set_subtitles_visible(&mut self, visible: bool) -> Result<(), EngineError> {
        self.command(&["set", "sub-visibility", if visible { "yes" } else { "no" }])
    }
    fn set_subtitle_scale(&mut self, scale: f64) -> Result<(), EngineError> {
        self.command(&["set", "sub-scale", &scale.to_string()])
    }
    fn set_subtitle_position(&mut self, position: f64) -> Result<(), EngineError> {
        self.command(&["set", "sub-pos", &position.to_string()])
    }
    fn set_video_aspect(&mut self, aspect: &str) -> Result<(), EngineError> {
        self.command(&["set", "video-aspect-override", aspect])
    }
    fn set_video_rotation(&mut self, degrees: i32) -> Result<(), EngineError> {
        self.command(&["set", "video-rotate", &degrees.to_string()])
    }
    fn set_video_flip(&mut self, flipped: bool) -> Result<(), EngineError> {
        self.command(&["set", "video-flip", if flipped { "yes" } else { "no" }])
    }
    fn set_screenshot_directory(&mut self, path: &Path) -> Result<(), EngineError> {
        self.command(&["set", "screenshot-directory", &path.to_string_lossy()])
    }
    fn screenshot(&mut self) -> Result<(), EngineError> {
        self.command(&["screenshot", "video"])
    }
    fn screenshot_to_file(&mut self, path: &Path) -> Result<(), EngineError> {
        self.command(&["screenshot-to-file", &path.to_string_lossy(), "video"])
    }
    fn select_track(&mut self, kind: TrackKind, track_id: Option<i64>) -> Result<(), EngineError> {
        let property = match kind {
            TrackKind::Video => "vid",
            TrackKind::Audio => "aid",
            TrackKind::Subtitle => "sid",
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
                    let tracks = self.tracks();
                    self.last_tracks = tracks.clone();
                    let (video_width, video_height) = self.video_display_size();
                    self.last_video_size = (video_width, video_height);
                    events.push(EngineEvent::FileLoaded {
                        duration_seconds: self.duration(),
                        video_width,
                        video_height,
                        tracks,
                        chapters: self.chapters(),
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
        let buffering = self
            .property_string("cache-buffering-state")
            .and_then(|value| value.parse::<f64>().ok());
        if buffering != self.last_buffering {
            self.last_buffering = buffering;
            events.push(EngineEvent::Buffering(buffering));
        }
        let video_size = self.video_display_size();
        if video_size != self.last_video_size {
            self.last_video_size = video_size;
            events.push(EngineEvent::VideoSizeChanged {
                video_width: video_size.0,
                video_height: video_size.1,
            });
        }
        if let Some(speed) = self
            .property_string("speed")
            .and_then(|value| value.parse::<f64>().ok())
        {
            if (speed - self.last_speed).abs() >= 0.001 {
                self.last_speed = speed;
                events.push(EngineEvent::SpeedChanged(speed));
            }
        }
        let tracks = self.tracks();
        if tracks != self.last_tracks {
            self.last_tracks = tracks.clone();
            events.push(EngineEvent::TracksChanged(tracks));
        }
        let audio_devices = self.audio_devices();
        if audio_devices != self.last_audio_devices {
            self.last_audio_devices = audio_devices.clone();
            events.push(EngineEvent::AudioDevicesChanged(audio_devices));
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
    fn seek_relative(&mut self, offset: f64) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .seek_relative(offset)
    }
    fn frame_step(&mut self) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .frame_step()
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
    fn set_speed(&mut self, speed: f64) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_speed(speed)
    }
    fn set_loop(&mut self, enabled: bool) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_loop(enabled)
    }
    fn set_ab_loop(&mut self, start: Option<f64>, end: Option<f64>) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_ab_loop(start, end)
    }
    fn set_subtitle_delay(&mut self, delay_seconds: f64) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_subtitle_delay(delay_seconds)
    }
    fn set_audio_delay(&mut self, delay_seconds: f64) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_audio_delay(delay_seconds)
    }
    fn set_audio_device(&mut self, device_id: &str) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_audio_device(device_id)
    }
    fn set_subtitles_visible(&mut self, visible: bool) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_subtitles_visible(visible)
    }
    fn set_subtitle_scale(&mut self, scale: f64) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_subtitle_scale(scale)
    }
    fn set_subtitle_position(&mut self, position: f64) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_subtitle_position(position)
    }
    fn set_video_aspect(&mut self, aspect: &str) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_video_aspect(aspect)
    }
    fn set_video_rotation(&mut self, degrees: i32) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_video_rotation(degrees)
    }
    fn set_video_flip(&mut self, flipped: bool) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_video_flip(flipped)
    }
    fn set_screenshot_directory(&mut self, path: &Path) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .set_screenshot_directory(path)
    }
    fn screenshot(&mut self) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .screenshot()
    }
    fn screenshot_to_file(&mut self, path: &Path) -> Result<(), EngineError> {
        self.0
            .lock()
            .map_err(|_| EngineError::Message("player lock poisoned".into()))?
            .screenshot_to_file(path)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_app_uses_override_then_bundled_library() {
        let candidates = mpv_library_candidates(
            Some(Path::new("/tmp/custom/libmpv.2.dylib")),
            Some(Path::new("/Applications/Nura.app/Contents/MacOS/Nura")),
            true,
        );

        assert_eq!(
            candidates,
            vec![
                PathBuf::from("/tmp/custom/libmpv.2.dylib"),
                PathBuf::from("/Applications/Nura.app/Contents/Frameworks/libmpv.2.dylib"),
            ]
        );
    }

    #[test]
    fn debug_app_keeps_homebrew_fallbacks() {
        let candidates = mpv_library_candidates(
            None,
            Some(Path::new("/tmp/Nura.app/Contents/MacOS/Nura")),
            false,
        );

        assert!(
            candidates
                .iter()
                .any(|path| path == Path::new("/opt/homebrew/lib/libmpv.2.dylib"))
        );
    }
}
