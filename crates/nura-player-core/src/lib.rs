use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use nura_domain::{
    Chapter, MediaItem, PlaybackSnapshot, PlaybackStatus, Track, TrackKind, is_resumable,
    same_name_subtitle,
};
use nura_library::HistoryRepository;
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub trait PlaybackEngine: Send {
    fn load(&mut self, item: &MediaItem, start_position_seconds: f64) -> Result<(), EngineError>;
    fn play(&mut self) -> Result<(), EngineError>;
    fn pause(&mut self) -> Result<(), EngineError>;
    fn seek(&mut self, position_seconds: f64) -> Result<(), EngineError>;
    fn seek_relative(&mut self, offset_seconds: f64) -> Result<(), EngineError>;
    fn frame_step(&mut self) -> Result<(), EngineError>;
    fn set_volume(&mut self, volume: f64) -> Result<(), EngineError>;
    fn set_mute(&mut self, muted: bool) -> Result<(), EngineError>;
    fn set_speed(&mut self, speed: f64) -> Result<(), EngineError>;
    fn set_loop(&mut self, enabled: bool) -> Result<(), EngineError>;
    fn set_ab_loop(&mut self, start: Option<f64>, end: Option<f64>) -> Result<(), EngineError>;
    fn set_subtitle_delay(&mut self, delay_seconds: f64) -> Result<(), EngineError>;
    fn screenshot(&mut self) -> Result<(), EngineError>;
    fn select_track(&mut self, kind: TrackKind, track_id: Option<i64>) -> Result<(), EngineError>;
    fn add_external_subtitle(&mut self, path: &Path) -> Result<(), EngineError>;
    fn stop(&mut self) -> Result<(), EngineError>;
    fn drain_events(&mut self) -> Result<Vec<EngineEvent>, EngineError>;
}

#[derive(Clone, Debug)]
pub enum EngineEvent {
    FileLoaded {
        duration_seconds: Option<f64>,
        tracks: Vec<Track>,
        chapters: Vec<Chapter>,
    },
    TracksChanged(Vec<Track>),
    PositionChanged(f64),
    SpeedChanged(f64),
    Buffering(Option<f64>),
    Paused(bool),
    Ended,
    Failed(String),
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PlayerEvent {
    State { snapshot: PlaybackSnapshot },
    Error { message: String },
}

pub struct PlayerSession<E, H> {
    engine: E,
    history: H,
    snapshot: PlaybackSnapshot,
    events: Vec<PlayerEvent>,
    last_persisted_position: f64,
}

impl<E: PlaybackEngine, H: HistoryRepository> PlayerSession<E, H> {
    pub fn new(engine: E, history: H) -> Self {
        Self {
            engine,
            history,
            snapshot: PlaybackSnapshot::default(),
            events: Vec::new(),
            last_persisted_position: 0.0,
        }
    }

    pub fn open(&mut self, path: impl Into<std::path::PathBuf>) -> Result<(), PlayerError> {
        let item = MediaItem::from_path(path)?;
        self.open_item(item)
    }

    pub fn open_url(&mut self, url: impl Into<String>) -> Result<(), PlayerError> {
        let item = MediaItem::from_url(url)?;
        self.open_item(item)
    }

    pub fn open_item(&mut self, item: MediaItem) -> Result<(), PlayerError> {
        self.persist_current_position()?;
        self.snapshot.playlist = vec![item.clone()];
        self.start_item(item, 0)
    }

    pub fn enqueue_item(&mut self, item: MediaItem) -> Result<(), PlayerError> {
        if self.snapshot.item.is_none() {
            return self.open_item(item);
        }
        self.snapshot.playlist.push(item);
        self.emit_state();
        Ok(())
    }

    pub fn remove_playlist_index(&mut self, index: usize) -> Result<(), PlayerError> {
        if index >= self.snapshot.playlist.len() {
            return Err(PlayerError::Engine(EngineError::Message(
                "playlist index is out of range".to_owned(),
            )));
        }
        self.snapshot.playlist.remove(index);
        let Some(current_index) = self.snapshot.playlist_index else {
            self.emit_state();
            return Ok(());
        };
        if self.snapshot.playlist.is_empty() {
            self.engine.stop()?;
            self.snapshot = PlaybackSnapshot {
                status: PlaybackStatus::Empty,
                speed: self.snapshot.speed,
                volume: self.snapshot.volume,
                muted: self.snapshot.muted,
                ..PlaybackSnapshot::default()
            };
            self.emit_state();
            return Ok(());
        }
        if index == current_index {
            let next_index = current_index.min(self.snapshot.playlist.len() - 1);
            let item = self.snapshot.playlist[next_index].clone();
            self.persist_current_position()?;
            self.start_item(item, next_index)
        } else {
            if index < current_index {
                self.snapshot.playlist_index = Some(current_index - 1);
            }
            self.emit_state();
            Ok(())
        }
    }

    pub fn move_playlist_item(&mut self, from: usize, to: usize) -> Result<(), PlayerError> {
        let len = self.snapshot.playlist.len();
        if from >= len || to >= len {
            return Err(PlayerError::Engine(EngineError::Message(
                "playlist index is out of range".to_owned(),
            )));
        }
        if from == to {
            return Ok(());
        }
        let current_key = self.snapshot.item.as_ref().map(MediaItem::path_key);
        let item = self.snapshot.playlist.remove(from);
        self.snapshot.playlist.insert(to, item);
        self.snapshot.playlist_index = current_key.and_then(|key| {
            self.snapshot
                .playlist
                .iter()
                .position(|item| item.path_key() == key)
        });
        self.emit_state();
        Ok(())
    }

    pub fn add_external_subtitle(
        &mut self,
        path: impl Into<std::path::PathBuf>,
    ) -> Result<(), PlayerError> {
        let path = path.into();
        if !path.is_file() {
            return Err(PlayerError::Domain(nura_domain::DomainError::MissingFile(
                path,
            )));
        }
        self.engine.add_external_subtitle(&path)?;
        Ok(())
    }

    pub fn play_playlist_index(&mut self, index: usize) -> Result<(), PlayerError> {
        let item = self.snapshot.playlist.get(index).cloned().ok_or_else(|| {
            PlayerError::Engine(EngineError::Message(
                "playlist index is out of range".to_owned(),
            ))
        })?;
        self.persist_current_position()?;
        self.start_item(item, index)
    }

    pub fn next(&mut self) -> Result<(), PlayerError> {
        let Some(index) = self.snapshot.playlist_index else {
            return Ok(());
        };
        if index + 1 < self.snapshot.playlist.len() {
            self.play_playlist_index(index + 1)?;
        }
        Ok(())
    }

    pub fn previous(&mut self) -> Result<(), PlayerError> {
        let Some(index) = self.snapshot.playlist_index else {
            return Ok(());
        };
        if self.snapshot.position_seconds > 3.0 {
            return self.seek(0.0);
        }
        if index > 0 {
            self.play_playlist_index(index - 1)?;
        }
        Ok(())
    }

    fn start_item(&mut self, item: MediaItem, index: usize) -> Result<(), PlayerError> {
        let resume_position = if item.is_local() {
            self.history.resume_position(&item)?.unwrap_or_default()
        } else {
            0.0
        };
        let playlist = self.snapshot.playlist.clone();
        self.snapshot = PlaybackSnapshot {
            item: Some(item.clone()),
            playlist,
            playlist_index: Some(index),
            status: PlaybackStatus::Loading,
            position_seconds: resume_position,
            speed: self.snapshot.speed,
            volume: self.snapshot.volume,
            muted: self.snapshot.muted,
            ..PlaybackSnapshot::default()
        };
        self.emit_state();

        if let Err(error) = self.engine.load(&item, resume_position) {
            self.fail(error.to_string());
            return Err(PlayerError::Engine(error));
        }
        if item.is_local() {
            self.history.remember(&item, Some(resume_position))?;
            if let Some(path) = item.local_path() {
                if let Some(subtitle) = same_name_subtitle(path) {
                    if let Err(error) = self.engine.add_external_subtitle(&subtitle) {
                        self.events.push(PlayerEvent::Error {
                            message: format!("Could not load external subtitle: {error}"),
                        });
                    }
                }
            }
        }
        Ok(())
    }

    pub fn play(&mut self) -> Result<(), PlayerError> {
        self.engine.play()?;
        self.snapshot.status = PlaybackStatus::Playing;
        self.emit_state();
        Ok(())
    }

    pub fn pause(&mut self) -> Result<(), PlayerError> {
        self.engine.pause()?;
        self.snapshot.status = PlaybackStatus::Paused;
        self.emit_state();
        Ok(())
    }

    pub fn toggle_playback(&mut self) -> Result<(), PlayerError> {
        if self.snapshot.status == PlaybackStatus::Playing {
            self.pause()
        } else {
            self.play()
        }
    }

    pub fn seek(&mut self, position_seconds: f64) -> Result<(), PlayerError> {
        let position_seconds = position_seconds.max(0.0);
        self.engine.seek(position_seconds)?;
        self.snapshot.position_seconds = position_seconds;
        self.emit_state();
        Ok(())
    }

    pub fn seek_relative(&mut self, offset_seconds: f64) -> Result<(), PlayerError> {
        self.engine.seek_relative(offset_seconds)?;
        self.snapshot.position_seconds = (self.snapshot.position_seconds + offset_seconds).max(0.0);
        self.emit_state();
        Ok(())
    }

    pub fn frame_step(&mut self) -> Result<(), PlayerError> {
        self.engine.frame_step()?;
        Ok(())
    }

    pub fn set_volume(&mut self, volume: f64) -> Result<(), PlayerError> {
        let volume = volume.clamp(0.0, 100.0);
        self.engine.set_volume(volume)?;
        self.snapshot.volume = volume;
        self.emit_state();
        Ok(())
    }

    pub fn set_mute(&mut self, muted: bool) -> Result<(), PlayerError> {
        self.engine.set_mute(muted)?;
        self.snapshot.muted = muted;
        self.emit_state();
        Ok(())
    }

    pub fn set_speed(&mut self, speed: f64) -> Result<(), PlayerError> {
        let speed = speed.clamp(0.25, 4.0);
        self.engine.set_speed(speed)?;
        self.snapshot.speed = speed;
        self.emit_state();
        Ok(())
    }

    pub fn set_subtitle_delay(&mut self, delay_seconds: f64) -> Result<(), PlayerError> {
        let delay_seconds = delay_seconds.clamp(-30.0, 30.0);
        self.engine.set_subtitle_delay(delay_seconds)?;
        self.snapshot.subtitle_delay_seconds = delay_seconds;
        self.emit_state();
        Ok(())
    }

    pub fn screenshot(&mut self) -> Result<(), PlayerError> {
        self.engine.screenshot()?;
        Ok(())
    }

    pub fn set_loop(&mut self, enabled: bool) -> Result<(), PlayerError> {
        self.engine.set_loop(enabled)?;
        Ok(())
    }

    pub fn set_playlist_loop(&mut self, enabled: bool) {
        self.snapshot.playlist_loop = enabled;
        self.emit_state();
    }

    pub fn shuffle_playlist(&mut self) {
        let Some(current_index) = self.snapshot.playlist_index else {
            return;
        };
        if current_index >= self.snapshot.playlist.len() {
            return;
        }
        let mut items = self.snapshot.playlist.clone();
        let current_item = items.remove(current_index);
        let mut seed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos() as u64)
            .unwrap_or(0x9e37_79b9);
        for index in (1..items.len()).rev() {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            let swap_index = (seed as usize) % (index + 1);
            items.swap(index, swap_index);
        }
        items.insert(0, current_item);
        self.snapshot.playlist = items;
        self.snapshot.playlist_index = Some(0);
        self.emit_state();
    }

    pub fn set_ab_loop(&mut self, start: Option<f64>, end: Option<f64>) -> Result<(), PlayerError> {
        let start = start.map(|value| value.max(0.0));
        let end = end.map(|value| value.max(0.0));
        if matches!((start, end), (Some(start), Some(end)) if end <= start) {
            return Err(PlayerError::Engine(EngineError::Message(
                "A-B loop end must be after its start".to_owned(),
            )));
        }
        self.engine.set_ab_loop(start, end)?;
        self.snapshot.ab_loop_start_seconds = start;
        self.snapshot.ab_loop_end_seconds = end;
        self.emit_state();
        Ok(())
    }

    pub fn select_track(
        &mut self,
        kind: TrackKind,
        track_id: Option<i64>,
    ) -> Result<(), PlayerError> {
        self.engine.select_track(kind, track_id)?;
        let tracks = match kind {
            TrackKind::Video => &mut self.snapshot.video_tracks,
            TrackKind::Audio => &mut self.snapshot.audio_tracks,
            TrackKind::Subtitle => &mut self.snapshot.subtitle_tracks,
        };
        for track in tracks {
            track.selected = Some(track.id) == track_id;
        }
        self.emit_state();
        Ok(())
    }

    pub fn poll(&mut self) -> Result<(), PlayerError> {
        for event in self.engine.drain_events()? {
            match event {
                EngineEvent::FileLoaded {
                    duration_seconds,
                    tracks,
                    chapters,
                } => {
                    self.snapshot.duration_seconds = duration_seconds;
                    self.snapshot.chapters = chapters;
                    self.snapshot.video_tracks = tracks
                        .iter()
                        .filter(|track| track.kind == TrackKind::Video)
                        .cloned()
                        .collect();
                    self.snapshot.audio_tracks = tracks
                        .iter()
                        .filter(|track| track.kind == TrackKind::Audio)
                        .cloned()
                        .collect();
                    self.snapshot.subtitle_tracks = tracks
                        .into_iter()
                        .filter(|track| track.kind == TrackKind::Subtitle)
                        .collect();
                    self.snapshot.status = PlaybackStatus::Playing;
                    self.snapshot.buffering_percent = None;
                    self.emit_state();
                }
                EngineEvent::TracksChanged(tracks) => {
                    self.snapshot.video_tracks = tracks
                        .iter()
                        .filter(|track| track.kind == TrackKind::Video)
                        .cloned()
                        .collect();
                    self.snapshot.audio_tracks = tracks
                        .iter()
                        .filter(|track| track.kind == TrackKind::Audio)
                        .cloned()
                        .collect();
                    self.snapshot.subtitle_tracks = tracks
                        .into_iter()
                        .filter(|track| track.kind == TrackKind::Subtitle)
                        .collect();
                    self.emit_state();
                }
                EngineEvent::PositionChanged(position) => {
                    self.snapshot.position_seconds = position;
                    self.persist_current_position()?;
                    self.emit_state();
                }
                EngineEvent::SpeedChanged(speed) => {
                    self.snapshot.speed = speed;
                    self.emit_state();
                }
                EngineEvent::Buffering(percent) => {
                    self.snapshot.status = if percent.is_some() {
                        PlaybackStatus::Buffering
                    } else {
                        PlaybackStatus::Playing
                    };
                    self.snapshot.buffering_percent = percent;
                    self.emit_state();
                }
                EngineEvent::Paused(paused) => {
                    self.snapshot.status = if paused {
                        PlaybackStatus::Paused
                    } else {
                        PlaybackStatus::Playing
                    };
                    self.emit_state();
                }
                EngineEvent::Ended => {
                    if let Some(item) = &self.snapshot.item {
                        self.history.clear_resume(item)?;
                    }
                    let next_index = self.snapshot.playlist_index.and_then(|index| {
                        (index + 1 < self.snapshot.playlist.len()).then_some(index + 1)
                    });
                    if let Some(next_index) = next_index {
                        if let Err(error) = self.play_playlist_index(next_index) {
                            self.fail(error.to_string());
                        }
                    } else if self.snapshot.playlist_loop && !self.snapshot.playlist.is_empty() {
                        if let Err(error) = self.play_playlist_index(0) {
                            self.fail(error.to_string());
                        }
                    } else {
                        self.snapshot.status = PlaybackStatus::Ended;
                        self.emit_state();
                    }
                }
                EngineEvent::Failed(message) => self.fail(message),
            }
        }
        Ok(())
    }

    pub fn shutdown(&mut self) -> Result<(), PlayerError> {
        self.persist_current_position()?;
        self.engine.stop()?;
        Ok(())
    }

    pub fn take_events(&mut self) -> Vec<PlayerEvent> {
        std::mem::take(&mut self.events)
    }

    fn persist_current_position(&mut self) -> Result<(), PlayerError> {
        let Some(item) = &self.snapshot.item else {
            return Ok(());
        };
        if (self.snapshot.position_seconds - self.last_persisted_position).abs() < 5.0 {
            return Ok(());
        }
        self.last_persisted_position = self.snapshot.position_seconds;
        if item.is_local()
            && is_resumable(
                self.snapshot.duration_seconds,
                self.snapshot.position_seconds,
            )
        {
            self.history
                .remember(item, Some(self.snapshot.position_seconds))?;
        } else if self.snapshot.status == PlaybackStatus::Ended {
            self.history.clear_resume(item)?;
        }
        Ok(())
    }

    fn emit_state(&mut self) {
        self.events.push(PlayerEvent::State {
            snapshot: self.snapshot.clone(),
        });
    }

    fn fail(&mut self, message: String) {
        self.snapshot.status = PlaybackStatus::Failed;
        self.snapshot.error = Some(message.clone());
        self.events.push(PlayerEvent::Error { message });
        self.emit_state();
    }
}

#[derive(Debug, Error)]
pub enum EngineError {
    #[error("{0}")]
    Message(String),
}

#[derive(Debug, Error)]
pub enum PlayerError {
    #[error(transparent)]
    Domain(#[from] nura_domain::DomainError),
    #[error(transparent)]
    History(#[from] nura_library::HistoryError),
    #[error(transparent)]
    Engine(#[from] EngineError),
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::fs;

    #[derive(Default)]
    struct FakeEngine {
        events: VecDeque<EngineEvent>,
        loaded_at: f64,
        ab_loop: (Option<f64>, Option<f64>),
        relative_seek: f64,
        frame_steps: usize,
        subtitle_delay: f64,
    }
    impl PlaybackEngine for FakeEngine {
        fn load(&mut self, _: &MediaItem, position: f64) -> Result<(), EngineError> {
            self.loaded_at = position;
            Ok(())
        }
        fn play(&mut self) -> Result<(), EngineError> {
            Ok(())
        }
        fn pause(&mut self) -> Result<(), EngineError> {
            Ok(())
        }
        fn seek(&mut self, _: f64) -> Result<(), EngineError> {
            Ok(())
        }
        fn seek_relative(&mut self, offset: f64) -> Result<(), EngineError> {
            self.relative_seek = offset;
            Ok(())
        }
        fn frame_step(&mut self) -> Result<(), EngineError> {
            self.frame_steps += 1;
            Ok(())
        }
        fn set_volume(&mut self, _: f64) -> Result<(), EngineError> {
            Ok(())
        }
        fn set_mute(&mut self, _: bool) -> Result<(), EngineError> {
            Ok(())
        }
        fn set_speed(&mut self, _: f64) -> Result<(), EngineError> {
            Ok(())
        }
        fn set_loop(&mut self, _: bool) -> Result<(), EngineError> {
            Ok(())
        }
        fn set_ab_loop(&mut self, start: Option<f64>, end: Option<f64>) -> Result<(), EngineError> {
            self.ab_loop = (start, end);
            Ok(())
        }
        fn set_subtitle_delay(&mut self, delay: f64) -> Result<(), EngineError> {
            self.subtitle_delay = delay;
            Ok(())
        }
        fn screenshot(&mut self) -> Result<(), EngineError> {
            Ok(())
        }
        fn select_track(&mut self, _: TrackKind, _: Option<i64>) -> Result<(), EngineError> {
            Ok(())
        }
        fn add_external_subtitle(&mut self, _: &Path) -> Result<(), EngineError> {
            Ok(())
        }
        fn stop(&mut self) -> Result<(), EngineError> {
            Ok(())
        }
        fn drain_events(&mut self) -> Result<Vec<EngineEvent>, EngineError> {
            Ok(self.events.drain(..).collect())
        }
    }

    struct MemoryHistory {
        resume: Option<f64>,
    }
    impl HistoryRepository for MemoryHistory {
        fn resume_position(
            &mut self,
            _: &MediaItem,
        ) -> Result<Option<f64>, nura_library::HistoryError> {
            Ok(self.resume)
        }
        fn remember(
            &mut self,
            _: &MediaItem,
            position: Option<f64>,
        ) -> Result<(), nura_library::HistoryError> {
            self.resume = position;
            Ok(())
        }
        fn clear_resume(&mut self, _: &MediaItem) -> Result<(), nura_library::HistoryError> {
            self.resume = None;
            Ok(())
        }
    }

    #[test]
    fn opening_restores_the_saved_position_and_autoplays_after_load() {
        let directory = std::env::temp_dir().join(format!("nura-core-test-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let media_path = directory.join("example.mkv");
        fs::write(&media_path, []).unwrap();
        let mut engine = FakeEngine::default();
        engine.events.push_back(EngineEvent::FileLoaded {
            duration_seconds: Some(120.0),
            tracks: vec![],
            chapters: vec![],
        });
        let mut session = PlayerSession::new(engine, MemoryHistory { resume: Some(24.0) });

        session.open(&media_path).unwrap();
        session.poll().unwrap();
        let events = session.take_events();
        assert!(events.iter().any(|event| matches!(event, PlayerEvent::State { snapshot } if snapshot.status == PlaybackStatus::Playing && snapshot.position_seconds == 24.0)));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn playlist_advances_and_previous_reloads_items() {
        let directory =
            std::env::temp_dir().join(format!("nura-playlist-test-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let first = directory.join("first.mkv");
        let second = directory.join("second.mkv");
        fs::write(&first, []).unwrap();
        fs::write(&second, []).unwrap();
        let mut engine = FakeEngine::default();
        engine.events.push_back(EngineEvent::FileLoaded {
            duration_seconds: Some(120.0),
            tracks: vec![],
            chapters: vec![],
        });
        let mut session = PlayerSession::new(engine, MemoryHistory { resume: None });
        session.open(&first).unwrap();
        session
            .enqueue_item(MediaItem::from_path(&second).unwrap())
            .unwrap();
        assert_eq!(session.snapshot.playlist.len(), 2);
        session.next().unwrap();
        assert_eq!(session.snapshot.playlist_index, Some(1));
        assert_eq!(session.snapshot.item.as_ref().unwrap().title, "second.mkv");
        session.previous().unwrap();
        assert_eq!(session.snapshot.playlist_index, Some(0));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn playlist_items_can_move_and_remove_without_losing_current_item() {
        let directory =
            std::env::temp_dir().join(format!("nura-playlist-edit-test-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let first = directory.join("first.mkv");
        let second = directory.join("second.mkv");
        let third = directory.join("third.mkv");
        for path in [&first, &second, &third] {
            fs::write(path, []).unwrap();
        }
        let mut engine = FakeEngine::default();
        engine.events.push_back(EngineEvent::FileLoaded {
            duration_seconds: Some(120.0),
            tracks: vec![],
            chapters: vec![],
        });
        let mut session = PlayerSession::new(engine, MemoryHistory { resume: None });
        session.open(&first).unwrap();
        session
            .enqueue_item(MediaItem::from_path(&second).unwrap())
            .unwrap();
        session
            .enqueue_item(MediaItem::from_path(&third).unwrap())
            .unwrap();
        session.move_playlist_item(2, 0).unwrap();
        assert_eq!(session.snapshot.playlist[0].title, "third.mkv");
        assert_eq!(session.snapshot.item.as_ref().unwrap().title, "first.mkv");
        assert_eq!(session.snapshot.playlist_index, Some(1));
        session.remove_playlist_index(1).unwrap();
        assert_eq!(session.snapshot.item.as_ref().unwrap().title, "second.mkv");
        assert_eq!(session.snapshot.playlist.len(), 2);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn playlist_loop_restarts_from_the_first_item_after_the_last_item_ends() {
        let directory =
            std::env::temp_dir().join(format!("nura-playlist-loop-test-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let first = directory.join("first.mkv");
        let second = directory.join("second.mkv");
        fs::write(&first, []).unwrap();
        fs::write(&second, []).unwrap();
        let mut session = PlayerSession::new(FakeEngine::default(), MemoryHistory { resume: None });
        session.open(&first).unwrap();
        session
            .enqueue_item(MediaItem::from_path(&second).unwrap())
            .unwrap();
        session.play_playlist_index(1).unwrap();
        session.set_playlist_loop(true);
        session.engine.events.push_back(EngineEvent::Ended);
        session.poll().unwrap();
        assert_eq!(session.snapshot.playlist_index, Some(0));
        assert_eq!(session.snapshot.item.as_ref().unwrap().title, "first.mkv");
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn ab_loop_updates_snapshot_and_rejects_an_invalid_range() {
        let mut session = PlayerSession::new(FakeEngine::default(), MemoryHistory { resume: None });
        session.set_ab_loop(Some(12.0), Some(24.0)).unwrap();
        assert_eq!(session.snapshot.ab_loop_start_seconds, Some(12.0));
        assert_eq!(session.snapshot.ab_loop_end_seconds, Some(24.0));
        assert_eq!(session.engine.ab_loop, (Some(12.0), Some(24.0)));
        assert!(session.set_ab_loop(Some(24.0), Some(12.0)).is_err());
        session.set_ab_loop(None, None).unwrap();
        assert_eq!(session.engine.ab_loop, (None, None));
    }

    #[test]
    fn relative_seek_frame_step_and_subtitle_delay_update_the_session() {
        let mut session = PlayerSession::new(FakeEngine::default(), MemoryHistory { resume: None });
        session.snapshot.position_seconds = 20.0;
        session.seek_relative(-5.0).unwrap();
        assert_eq!(session.snapshot.position_seconds, 15.0);
        assert_eq!(session.engine.relative_seek, -5.0);
        session.frame_step().unwrap();
        assert_eq!(session.engine.frame_steps, 1);
        session.set_subtitle_delay(0.5).unwrap();
        assert_eq!(session.snapshot.subtitle_delay_seconds, 0.5);
        assert_eq!(session.engine.subtitle_delay, 0.5);
    }
}
