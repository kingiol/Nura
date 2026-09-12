use std::collections::VecDeque;
use std::ffi::{CStr, CString, c_char, c_int};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, TryLockError, mpsc};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use nura_domain::TrackKind;
use nura_library::SqliteHistoryRepository;
use nura_mpv::{MpvEngine, MpvStartupOptions, SharedMpvEngine};
use nura_player_core::{PlayerEvent, PlayerSession};

type Reply = mpsc::SyncSender<Result<(), String>>;

// A busy engine is a normal dropped video frame, not a render failure.
const NURA_RENDER_SKIPPED: c_int = 1;

enum Command {
    Open(PathBuf, Reply),
    Enqueue(PathBuf, Reply),
    ClearPlaylist(Reply),
    RemoveIndex(usize, Reply),
    MoveIndex {
        from: usize,
        to: usize,
        reply: Reply,
    },
    PlayIndex(usize, Reply),
    Next(Reply),
    Previous(Reply),
    Play(Reply),
    Pause(Reply),
    Toggle(Reply),
    Seek(f64, Reply),
    SeekRelative(f64, Reply),
    FrameStep(Reply),
    FrameBackStep(Reply),
    Volume(f64, Reply),
    Mute(bool, Reply),
    Speed(f64, Reply),
    Loop(bool, Reply),
    PlaylistLoop(bool, Reply),
    Shuffle(Reply),
    AbLoop {
        start: Option<f64>,
        end: Option<f64>,
        reply: Reply,
    },
    SubtitleDelay(f64, Reply),
    Screenshot(Reply),
    ScreenshotToFile(PathBuf, Reply),
    AudioTrack(Option<i64>, Reply),
    SubtitleTrack(Option<i64>, Reply),
    VideoTrack(Option<i64>, Reply),
    Async(AsyncCommand),
    Shutdown(Reply),
}

enum AsyncCommand {
    Open(PathBuf),
    Enqueue(PathBuf),
    ClearPlaylist,
    RemoveIndex(usize),
    MoveIndex {
        from: usize,
        to: usize,
    },
    PlayIndex(usize),
    Next,
    Previous,
    Toggle,
    Seek(f64),
    SeekRelative(f64),
    FrameStep,
    FrameBackStep,
    Mute(bool),
    Speed(f64),
    Loop(bool),
    PlaylistLoop(bool),
    Shuffle,
    AbLoop {
        start: Option<f64>,
        end: Option<f64>,
    },
    SubtitleDelay(f64),
    AudioDelay(f64),
    AudioDevice(String),
    SubtitleVisibility(bool),
    SubtitleScale(f64),
    SubtitlePosition(f64),
    VideoAspect(String),
    VideoRotation(i32),
    VideoFlip(bool),
    ScreenshotDirectory(PathBuf),
    Screenshot,
    AudioTrack(Option<i64>),
    SubtitleTrack(Option<i64>),
    VideoTrack(Option<i64>),
    ExternalSubtitle(PathBuf),
    RemoveHistoryItem(String),
    ClearHistory,
}

pub struct NuraPlayer {
    commands: mpsc::SyncSender<Command>,
    pending_volume: Arc<Mutex<Option<f64>>>,
    events: Arc<Mutex<VecDeque<PlayerEvent>>>,
    engine: SharedMpvEngine,
    worker: Option<JoinHandle<()>>,
}

static LAST_ERROR: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn last_error_slot() -> &'static Mutex<Option<String>> {
    LAST_ERROR.get_or_init(|| Mutex::new(None))
}

fn set_last_error(error: impl Into<String>) {
    if let Ok(mut slot) = last_error_slot().lock() {
        *slot = Some(error.into());
    }
}

fn take_last_error() -> CString {
    let value = last_error_slot()
        .lock()
        .ok()
        .and_then(|mut slot| slot.take())
        .unwrap_or_default();
    CString::new(value).unwrap_or_default()
}

fn push_events(
    session: &mut PlayerSession<SharedMpvEngine, SqliteHistoryRepository>,
    events: &Arc<Mutex<VecDeque<PlayerEvent>>>,
) {
    if let Ok(mut queue) = events.lock() {
        queue.extend(session.take_events());
    }
}

fn push_error(events: &Arc<Mutex<VecDeque<PlayerEvent>>>, error: impl Into<String>) {
    if let Ok(mut queue) = events.lock() {
        queue.push_back(PlayerEvent::Error {
            message: error.into(),
        });
    }
}

fn open_locator(
    session: &mut PlayerSession<SharedMpvEngine, SqliteHistoryRepository>,
    locator: PathBuf,
) -> Result<(), nura_player_core::PlayerError> {
    let locator = locator.to_string_lossy().into_owned();
    if locator.starts_with("http://") || locator.starts_with("https://") {
        session.open_url(locator)
    } else {
        session.open(locator)
    }
}

fn handle_async_command(
    session: &mut PlayerSession<SharedMpvEngine, SqliteHistoryRepository>,
    command: AsyncCommand,
    events: &Arc<Mutex<VecDeque<PlayerEvent>>>,
) {
    let result = match command {
        AsyncCommand::Open(path) => open_locator(session, path),
        AsyncCommand::Enqueue(path) => {
            let locator = path.to_string_lossy().into_owned();
            if locator.starts_with("http://") || locator.starts_with("https://") {
                nura_domain::MediaItem::from_url(locator)
                    .map_err(nura_player_core::PlayerError::Domain)
                    .and_then(|item| session.enqueue_item(item))
            } else {
                nura_domain::MediaItem::from_path(path)
                    .map_err(nura_player_core::PlayerError::Domain)
                    .and_then(|item| session.enqueue_item(item))
            }
        }
        AsyncCommand::ClearPlaylist => session.clear_playlist(),
        AsyncCommand::RemoveIndex(index) => session.remove_playlist_index(index),
        AsyncCommand::MoveIndex { from, to } => session.move_playlist_item(from, to),
        AsyncCommand::PlayIndex(index) => session.play_playlist_index(index),
        AsyncCommand::Next => session.next(),
        AsyncCommand::Previous => session.previous(),
        AsyncCommand::Toggle => session.toggle_playback(),
        AsyncCommand::Seek(position) => session.seek(position),
        AsyncCommand::SeekRelative(offset) => session.seek_relative(offset),
        AsyncCommand::FrameStep => session.frame_step(),
        AsyncCommand::FrameBackStep => session.frame_back_step(),
        AsyncCommand::Mute(muted) => session.set_mute(muted),
        AsyncCommand::Speed(speed) => session.set_speed(speed),
        AsyncCommand::Loop(enabled) => session.set_loop(enabled),
        AsyncCommand::PlaylistLoop(enabled) => {
            session.set_playlist_loop(enabled);
            Ok(())
        }
        AsyncCommand::Shuffle => {
            session.shuffle_playlist();
            Ok(())
        }
        AsyncCommand::AbLoop { start, end } => session.set_ab_loop(start, end),
        AsyncCommand::SubtitleDelay(delay) => session.set_subtitle_delay(delay),
        AsyncCommand::AudioDelay(delay) => session.set_audio_delay(delay),
        AsyncCommand::AudioDevice(device_id) => session.set_audio_device(device_id),
        AsyncCommand::SubtitleVisibility(visible) => session.set_subtitles_visible(visible),
        AsyncCommand::SubtitleScale(scale) => session.set_subtitle_scale(scale),
        AsyncCommand::SubtitlePosition(position) => session.set_subtitle_position(position),
        AsyncCommand::VideoAspect(aspect) => session.set_video_aspect(aspect),
        AsyncCommand::VideoRotation(degrees) => session.set_video_rotation(degrees),
        AsyncCommand::VideoFlip(flipped) => session.set_video_flip(flipped),
        AsyncCommand::ScreenshotDirectory(path) => session.set_screenshot_directory(path),
        AsyncCommand::Screenshot => session.screenshot(),
        AsyncCommand::AudioTrack(id) => session.select_track(TrackKind::Audio, id),
        AsyncCommand::SubtitleTrack(id) => session.select_track(TrackKind::Subtitle, id),
        AsyncCommand::VideoTrack(id) => session.select_track(TrackKind::Video, id),
        AsyncCommand::ExternalSubtitle(path) => session.add_external_subtitle(path),
        AsyncCommand::RemoveHistoryItem(path_key) => session.remove_history_item(&path_key),
        AsyncCommand::ClearHistory => session.clear_history(),
    };
    if let Err(error) = result {
        push_error(events, error.to_string());
    }
}

fn set_pending_volume(pending_volume: &Mutex<Option<f64>>, volume: f64) -> Result<(), String> {
    let mut pending_volume = pending_volume
        .lock()
        .map_err(|_| "pending volume lock poisoned".to_owned())?;
    *pending_volume = Some(volume);
    Ok(())
}

fn take_pending_volume(pending_volume: &Mutex<Option<f64>>) -> Option<f64> {
    pending_volume
        .lock()
        .ok()
        .and_then(|mut volume| volume.take())
}

fn apply_pending_volume(
    session: &mut PlayerSession<SharedMpvEngine, SqliteHistoryRepository>,
    pending_volume: &Mutex<Option<f64>>,
    events: &Arc<Mutex<VecDeque<PlayerEvent>>>,
) {
    let Some(volume) = take_pending_volume(pending_volume) else {
        return;
    };
    if let Err(error) = session.set_volume(volume) {
        push_error(events, error.to_string());
    }
}

fn handle_command(
    session: &mut PlayerSession<SharedMpvEngine, SqliteHistoryRepository>,
    command: Command,
    events: &Arc<Mutex<VecDeque<PlayerEvent>>>,
) -> bool {
    let (operation, reply) = match command {
        Command::Open(path, reply) => (open_locator(session, path), reply),
        Command::Enqueue(path, reply) => {
            let locator = path.to_string_lossy().into_owned();
            let result = if locator.starts_with("http://") || locator.starts_with("https://") {
                nura_domain::MediaItem::from_url(locator)
                    .map_err(nura_player_core::PlayerError::Domain)
                    .and_then(|item| session.enqueue_item(item))
            } else {
                nura_domain::MediaItem::from_path(path)
                    .map_err(nura_player_core::PlayerError::Domain)
                    .and_then(|item| session.enqueue_item(item))
            };
            (result, reply)
        }
        Command::ClearPlaylist(reply) => (session.clear_playlist(), reply),
        Command::RemoveIndex(index, reply) => (session.remove_playlist_index(index), reply),
        Command::MoveIndex { from, to, reply } => (session.move_playlist_item(from, to), reply),
        Command::PlayIndex(index, reply) => (session.play_playlist_index(index), reply),
        Command::Next(reply) => (session.next(), reply),
        Command::Previous(reply) => (session.previous(), reply),
        Command::Play(reply) => (session.play(), reply),
        Command::Pause(reply) => (session.pause(), reply),
        Command::Toggle(reply) => (session.toggle_playback(), reply),
        Command::Async(command) => {
            handle_async_command(session, command, events);
            return false;
        }
        Command::Seek(position, reply) => (session.seek(position), reply),
        Command::SeekRelative(offset, reply) => (session.seek_relative(offset), reply),
        Command::FrameStep(reply) => (session.frame_step(), reply),
        Command::FrameBackStep(reply) => (session.frame_back_step(), reply),
        Command::Volume(volume, reply) => (session.set_volume(volume), reply),
        Command::Mute(muted, reply) => (session.set_mute(muted), reply),
        Command::Speed(speed, reply) => (session.set_speed(speed), reply),
        Command::Loop(enabled, reply) => (session.set_loop(enabled), reply),
        Command::PlaylistLoop(enabled, reply) => {
            session.set_playlist_loop(enabled);
            (Ok(()), reply)
        }
        Command::Shuffle(reply) => {
            session.shuffle_playlist();
            (Ok(()), reply)
        }
        Command::AbLoop { start, end, reply } => (session.set_ab_loop(start, end), reply),
        Command::SubtitleDelay(delay, reply) => (session.set_subtitle_delay(delay), reply),
        Command::Screenshot(reply) => (session.screenshot(), reply),
        Command::ScreenshotToFile(path, reply) => (session.screenshot_to_file(path), reply),
        Command::AudioTrack(id, reply) => (session.select_track(TrackKind::Audio, id), reply),
        Command::SubtitleTrack(id, reply) => (session.select_track(TrackKind::Subtitle, id), reply),
        Command::VideoTrack(id, reply) => (session.select_track(TrackKind::Video, id), reply),
        Command::Shutdown(reply) => {
            let result = session.shutdown().map_err(|error| error.to_string());
            let _ = reply.send(result);
            return true;
        }
    };
    let result = operation.map_err(|error| error.to_string());
    let _ = reply.send(result);
    false
}

fn spawn_worker(
    receiver: mpsc::Receiver<Command>,
    engine: SharedMpvEngine,
    history_path: PathBuf,
    pending_volume: Arc<Mutex<Option<f64>>>,
    events: Arc<Mutex<VecDeque<PlayerEvent>>>,
) -> Result<JoinHandle<()>, String> {
    let history = SqliteHistoryRepository::open(history_path).map_err(|error| error.to_string())?;
    Ok(thread::spawn(move || {
        let mut session = PlayerSession::new(engine, history);
        loop {
            match receiver.recv_timeout(Duration::from_millis(100)) {
                Ok(command) => {
                    if handle_command(&mut session, command, &events) {
                        break;
                    }
                }

                Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
            apply_pending_volume(&mut session, &pending_volume, &events);
            if let Err(error) = session.poll() {
                push_error(&events, error.to_string());
            }
            push_events(&mut session, &events);
        }
        push_events(&mut session, &events);
    }))
}

fn send_command(player: &NuraPlayer, command: impl FnOnce(Reply) -> Command) -> Result<(), String> {
    let (sender, receiver) = mpsc::sync_channel(1);
    player
        .commands
        .send(command(sender))
        .map_err(|_| "player worker has stopped".to_owned())?;
    receiver
        .recv()
        .map_err(|_| "player worker did not reply".to_owned())?
}

fn enqueue_command(commands: &mpsc::SyncSender<Command>, command: Command) -> Result<(), String> {
    commands.try_send(command).map_err(|error| match error {
        mpsc::TrySendError::Full(_) => "player command queue is full".to_owned(),
        mpsc::TrySendError::Disconnected(_) => "player worker has stopped".to_owned(),
    })
}

fn enqueue_async(
    commands: &mpsc::SyncSender<Command>,
    command: AsyncCommand,
) -> Result<(), String> {
    enqueue_command(commands, Command::Async(command))
}

fn try_lock_for_render<T>(mutex: &Mutex<T>) -> Result<Option<MutexGuard<'_, T>>, String> {
    match mutex.try_lock() {
        Ok(value) => Ok(Some(value)),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Poisoned(_)) => Err("player lock poisoned".to_owned()),
    }
}

unsafe fn read_string(value: *const c_char) -> Result<String, String> {
    if value.is_null() {
        return Err("received a null string".to_owned());
    }
    CStr::from_ptr(value)
        .to_str()
        .map(|value| value.to_owned())
        .map_err(|_| "received invalid UTF-8".to_owned())
}

#[unsafe(no_mangle)]
pub extern "C" fn nura_last_error() -> *mut c_char {
    take_last_error().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn nura_player_create(
    data_directory: *const c_char,
    startup_options_json: *const c_char,
) -> *mut NuraPlayer {
    let result: Result<Box<NuraPlayer>, String> = (|| {
        let data_directory = unsafe { read_string(data_directory) }?;
        let startup_options = if startup_options_json.is_null() {
            MpvStartupOptions::default()
        } else {
            let value = unsafe { read_string(startup_options_json) }?;
            serde_json::from_str(&value)
                .map_err(|error| format!("invalid player settings: {error}"))?
        };
        let directory = PathBuf::from(data_directory);
        std::fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
        let engine = SharedMpvEngine(Arc::new(Mutex::new(
            MpvEngine::new(startup_options).map_err(|error| error.to_string())?,
        )));
        let (sender, receiver) = mpsc::sync_channel(32);
        let pending_volume = Arc::new(Mutex::new(None));
        let events = Arc::new(Mutex::new(VecDeque::new()));
        let worker = spawn_worker(
            receiver,
            engine.clone(),
            directory.join("history.sqlite"),
            pending_volume.clone(),
            events.clone(),
        )?;
        Ok(Box::new(NuraPlayer {
            commands: sender,
            pending_volume,
            events,
            engine,
            worker: Some(worker),
        }))
    })();
    match result {
        Ok(player) => Box::into_raw(player),
        Err(error) => {
            set_last_error(error);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_destroy(player: *mut NuraPlayer) {
    if player.is_null() {
        return;
    }
    let player = Box::from_raw(player);
    std::thread::spawn(move || {
        let mut player = player;
        let _ = send_command(&player, Command::Shutdown);
        if let Some(worker) = player.worker.take() {
            let _ = worker.join();
        }
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_open(player: *mut NuraPlayer, path: *const c_char) -> c_int {
    let path = match read_string(path) {
        Ok(path) => path,
        Err(error) => {
            set_last_error(error);
            return -1;
        }
    };
    command_result(player, move |reply| {
        Command::Open(PathBuf::from(path), reply)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_open_async(
    player: *mut NuraPlayer,
    path: *const c_char,
) -> c_int {
    let path = match read_string(path) {
        Ok(path) => path,
        Err(error) => {
            set_last_error(error);
            return -1;
        }
    };
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::Open(PathBuf::from(path)))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_open_url_async(
    player: *mut NuraPlayer,
    url: *const c_char,
) -> c_int {
    let url = match read_string(url) {
        Ok(url) => url,
        Err(error) => {
            set_last_error(error);
            return -1;
        }
    };
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::Open(PathBuf::from(url)))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_enqueue_async(
    player: *mut NuraPlayer,
    locator: *const c_char,
) -> c_int {
    let locator = match read_string(locator) {
        Ok(locator) => locator,
        Err(error) => {
            set_last_error(error);
            return -1;
        }
    };
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::Enqueue(PathBuf::from(locator)))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_clear_playlist_async(player: *mut NuraPlayer) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::ClearPlaylist)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_remove_index_async(
    player: *mut NuraPlayer,
    index: usize,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::RemoveIndex(index))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_move_index_async(
    player: *mut NuraPlayer,
    from: usize,
    to: usize,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::MoveIndex { from, to })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_play_index_async(
    player: *mut NuraPlayer,
    index: usize,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::PlayIndex(index))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_next_async(player: *mut NuraPlayer) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::Next)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_previous_async(player: *mut NuraPlayer) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::Previous)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_play(player: *mut NuraPlayer) -> c_int {
    command_result(player, Command::Play)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_pause(player: *mut NuraPlayer) -> c_int {
    command_result(player, Command::Pause)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_toggle(player: *mut NuraPlayer) -> c_int {
    command_result(player, Command::Toggle)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_toggle_async(player: *mut NuraPlayer) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::Toggle)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_seek(player: *mut NuraPlayer, position: f64) -> c_int {
    command_result(player, |reply| Command::Seek(position, reply))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_seek_async(player: *mut NuraPlayer, position: f64) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::Seek(position))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_seek_relative_async(
    player: *mut NuraPlayer,
    offset: f64,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::SeekRelative(offset))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_frame_step_async(player: *mut NuraPlayer) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::FrameStep)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_frame_back_step_async(player: *mut NuraPlayer) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::FrameBackStep)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_volume(player: *mut NuraPlayer, volume: f64) -> c_int {
    command_result(player, |reply| Command::Volume(volume, reply))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_volume_async(
    player: *mut NuraPlayer,
    volume: f64,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    match set_pending_volume(&player.pending_volume, volume) {
        Ok(()) => 0,
        Err(error) => {
            set_last_error(error);
            -1
        }
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_mute(player: *mut NuraPlayer, muted: c_int) -> c_int {
    command_result(player, |reply| Command::Mute(muted != 0, reply))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_mute_async(
    player: *mut NuraPlayer,
    muted: c_int,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::Mute(muted != 0))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_speed_async(player: *mut NuraPlayer, speed: f64) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::Speed(speed))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_screenshot_async(player: *mut NuraPlayer) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::Screenshot)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_screenshot_to_file(
    player: *mut NuraPlayer,
    path: *const c_char,
) -> c_int {
    let path = match read_string(path) {
        Ok(path) => path,
        Err(error) => {
            set_last_error(error);
            return -1;
        }
    };
    command_result(player, move |reply| {
        Command::ScreenshotToFile(PathBuf::from(path), reply)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_loop_async(
    player: *mut NuraPlayer,
    enabled: c_int,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::Loop(enabled != 0))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_playlist_loop_async(
    player: *mut NuraPlayer,
    enabled: c_int,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::PlaylistLoop(enabled != 0))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_shuffle_async(player: *mut NuraPlayer) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::Shuffle)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_ab_loop_async(
    player: *mut NuraPlayer,
    start: f64,
    end: f64,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    let start = start.is_finite().then_some(start);
    let end = end.is_finite().then_some(end);
    async_command_result(player, AsyncCommand::AbLoop { start, end })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_subtitle_delay_async(
    player: *mut NuraPlayer,
    delay: f64,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::SubtitleDelay(delay))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_audio_delay_async(
    player: *mut NuraPlayer,
    delay: f64,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::AudioDelay(delay))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_audio_device_async(
    player: *mut NuraPlayer,
    device_id: *const c_char,
) -> c_int {
    let device_id = match read_string(device_id) {
        Ok(value) => value,
        Err(error) => {
            set_last_error(error);
            return -1;
        }
    };
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::AudioDevice(device_id))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_subtitle_visibility_async(
    player: *mut NuraPlayer,
    visible: c_int,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::SubtitleVisibility(visible != 0))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_subtitle_scale_async(
    player: *mut NuraPlayer,
    scale: f64,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::SubtitleScale(scale))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_subtitle_position_async(
    player: *mut NuraPlayer,
    position: f64,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::SubtitlePosition(position))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_video_aspect_async(
    player: *mut NuraPlayer,
    aspect: *const c_char,
) -> c_int {
    let aspect = match read_string(aspect) {
        Ok(value) => value,
        Err(error) => {
            set_last_error(error);
            return -1;
        }
    };
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::VideoAspect(aspect))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_video_rotation_async(
    player: *mut NuraPlayer,
    degrees: c_int,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::VideoRotation(degrees))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_video_flip_async(
    player: *mut NuraPlayer,
    flipped: c_int,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::VideoFlip(flipped != 0))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_set_screenshot_directory_async(
    player: *mut NuraPlayer,
    directory: *const c_char,
) -> c_int {
    let directory = match read_string(directory) {
        Ok(value) => value,
        Err(error) => {
            set_last_error(error);
            return -1;
        }
    };
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(
        player,
        AsyncCommand::ScreenshotDirectory(PathBuf::from(directory)),
    )
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_select_audio_track(
    player: *mut NuraPlayer,
    track_id: i64,
) -> c_int {
    command_result(player, |reply| {
        Command::AudioTrack((track_id >= 0).then_some(track_id), reply)
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_select_audio_track_async(
    player: *mut NuraPlayer,
    track_id: i64,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(
        player,
        AsyncCommand::AudioTrack((track_id >= 0).then_some(track_id)),
    )
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_select_subtitle_track(
    player: *mut NuraPlayer,
    track_id: i64,
) -> c_int {
    command_result(player, |reply| {
        Command::SubtitleTrack((track_id >= 0).then_some(track_id), reply)
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_select_subtitle_track_async(
    player: *mut NuraPlayer,
    track_id: i64,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(
        player,
        AsyncCommand::SubtitleTrack((track_id >= 0).then_some(track_id)),
    )
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_select_video_track_async(
    player: *mut NuraPlayer,
    track_id: i64,
) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(
        player,
        AsyncCommand::VideoTrack((track_id >= 0).then_some(track_id)),
    )
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_add_external_subtitle_async(
    player: *mut NuraPlayer,
    path: *const c_char,
) -> c_int {
    let path = match read_string(path) {
        Ok(path) => path,
        Err(error) => {
            set_last_error(error);
            return -1;
        }
    };
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::ExternalSubtitle(PathBuf::from(path)))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_remove_history_item_async(
    player: *mut NuraPlayer,
    path_key: *const c_char,
) -> c_int {
    let path_key = match read_string(path_key) {
        Ok(value) => value,
        Err(error) => {
            set_last_error(error);
            return -1;
        }
    };
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::RemoveHistoryItem(path_key))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_clear_history_async(player: *mut NuraPlayer) -> c_int {
    let Some(player) = player.as_ref() else {
        set_last_error("player is unavailable");
        return -1;
    };
    async_command_result(player, AsyncCommand::ClearHistory)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_attach_opengl_context(player: *mut NuraPlayer) -> c_int {
    let Some(player) = player.as_ref() else {
        return -1;
    };
    match player
        .engine
        .0
        .lock()
        .map_err(|_| "player lock poisoned".to_owned())
        .and_then(|mut engine| {
            engine
                .attach_opengl_context()
                .map_err(|error| error.to_string())
        }) {
        Ok(()) => 0,
        Err(error) => {
            set_last_error(error.to_string());
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_detach_opengl_context(player: *mut NuraPlayer) -> c_int {
    let Some(player) = player.as_ref() else {
        return -1;
    };
    match player
        .engine
        .0
        .lock()
        .map_err(|_| "player lock poisoned".to_owned())
    {
        Ok(mut engine) => {
            engine.detach_opengl_context();
            0
        }
        Err(error) => {
            set_last_error(error);
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_render_opengl(
    player: *mut NuraPlayer,
    fbo: i32,
    width: i32,
    height: i32,
) -> c_int {
    let Some(player) = player.as_ref() else {
        return -1;
    };
    match try_lock_for_render(&player.engine.0) {
        Ok(Some(mut engine)) => match engine.render_opengl(fbo, width, height) {
            Ok(()) => 0,
            Err(error) => {
                set_last_error(error.to_string());
                -1
            }
        },
        Ok(None) => NURA_RENDER_SKIPPED,
        Err(error) => {
            set_last_error(error);
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_player_next_event(player: *mut NuraPlayer) -> *mut c_char {
    let Some(player) = player.as_ref() else {
        return std::ptr::null_mut();
    };
    let event = player
        .events
        .lock()
        .ok()
        .and_then(|mut queue| queue.pop_front());
    event
        .and_then(|event| serde_json::to_string(&event).ok())
        .and_then(|event| CString::new(event).ok())
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nura_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

unsafe fn command_result(player: *mut NuraPlayer, command: impl FnOnce(Reply) -> Command) -> c_int {
    let Some(player) = player.as_ref() else {
        return -1;
    };
    match send_command(player, command) {
        Ok(()) => 0,
        Err(error) => {
            set_last_error(error);
            -1
        }
    }
}

fn async_command_result(player: &NuraPlayer, command: AsyncCommand) -> c_int {
    match enqueue_async(&player.commands, command) {
        Ok(()) => 0,
        Err(error) => {
            set_last_error(error);
            -1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enqueue_toggle_does_not_wait_for_worker_reply() {
        let (commands, receiver) = mpsc::sync_channel(1);

        enqueue_async(&commands, AsyncCommand::Toggle).expect("toggle should be queued");

        let command = receiver.try_recv().expect("command should be available");
        match command {
            Command::Async(AsyncCommand::Toggle) => {}
            _ => panic!("expected asynchronous toggle command"),
        }
    }

    #[test]
    fn enqueue_mute_does_not_wait_for_worker_reply() {
        let (commands, receiver) = mpsc::sync_channel(1);

        enqueue_async(&commands, AsyncCommand::Mute(true)).expect("mute should be queued");

        let command = receiver.try_recv().expect("command should be available");
        match command {
            Command::Async(AsyncCommand::Mute(true)) => {}
            _ => panic!("expected asynchronous mute command"),
        }
    }

    #[test]
    fn enqueue_seek_and_track_changes_do_not_wait_for_worker_reply() {
        let (commands, receiver) = mpsc::sync_channel(3);

        enqueue_async(&commands, AsyncCommand::Seek(42.0)).expect("seek should be queued");
        enqueue_async(&commands, AsyncCommand::AudioTrack(Some(1)))
            .expect("audio track should be queued");
        enqueue_async(&commands, AsyncCommand::SubtitleTrack(None))
            .expect("subtitle track should be queued");

        match receiver.try_recv().expect("seek should be available") {
            Command::Async(AsyncCommand::Seek(position)) => assert_eq!(position, 42.0),
            _ => panic!("expected asynchronous seek command"),
        }
        match receiver
            .try_recv()
            .expect("audio track should be available")
        {
            Command::Async(AsyncCommand::AudioTrack(Some(1))) => {}
            _ => panic!("expected asynchronous audio track command"),
        }
        match receiver
            .try_recv()
            .expect("subtitle track should be available")
        {
            Command::Async(AsyncCommand::SubtitleTrack(None)) => {}
            _ => panic!("expected asynchronous subtitle track command"),
        }
    }

    #[test]
    fn pending_volume_keeps_only_the_latest_value() {
        let pending_volume = Mutex::new(None);

        set_pending_volume(&pending_volume, 20.0).expect("first volume should be accepted");
        set_pending_volume(&pending_volume, 80.0).expect("latest volume should be accepted");

        assert_eq!(take_pending_volume(&pending_volume), Some(80.0));
        assert_eq!(take_pending_volume(&pending_volume), None);
    }

    #[test]
    fn render_lock_skips_busy_worker_instead_of_waiting() {
        let engine = Mutex::new(());
        let worker_guard = engine.lock().expect("worker should acquire the lock");

        assert!(
            try_lock_for_render(&engine)
                .expect("busy lock is not an error")
                .is_none()
        );

        drop(worker_guard);

        assert!(
            try_lock_for_render(&engine)
                .expect("available lock should succeed")
                .is_some()
        );
    }
}
