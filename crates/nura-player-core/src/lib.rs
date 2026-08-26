use std::path::Path;

use nura_domain::{
    MediaItem, PlaybackSnapshot, PlaybackStatus, Track, TrackKind, is_resumable, same_name_subtitle,
};
use nura_library::HistoryRepository;
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub trait PlaybackEngine: Send {
    fn load(&mut self, item: &MediaItem, start_position_seconds: f64) -> Result<(), EngineError>;
    fn play(&mut self) -> Result<(), EngineError>;
    fn pause(&mut self) -> Result<(), EngineError>;
    fn seek(&mut self, position_seconds: f64) -> Result<(), EngineError>;
    fn set_volume(&mut self, volume: f64) -> Result<(), EngineError>;
    fn set_mute(&mut self, muted: bool) -> Result<(), EngineError>;
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
    },
    PositionChanged(f64),
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
        self.persist_current_position()?;
        let item = MediaItem::from_path(path)?;
        let resume_position = self.history.resume_position(&item)?.unwrap_or_default();
        self.snapshot = PlaybackSnapshot {
            item: Some(item.clone()),
            status: PlaybackStatus::Loading,
            position_seconds: resume_position,
            volume: self.snapshot.volume,
            muted: self.snapshot.muted,
            ..PlaybackSnapshot::default()
        };
        self.emit_state();

        if let Err(error) = self.engine.load(&item, resume_position) {
            self.fail(error.to_string());
            return Err(PlayerError::Engine(error));
        }
        self.history.remember(&item, Some(resume_position))?;
        if let Some(subtitle) = same_name_subtitle(&item.path) {
            if let Err(error) = self.engine.add_external_subtitle(&subtitle) {
                self.events.push(PlayerEvent::Error {
                    message: format!("Could not load external subtitle: {error}"),
                });
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

    pub fn select_track(
        &mut self,
        kind: TrackKind,
        track_id: Option<i64>,
    ) -> Result<(), PlayerError> {
        self.engine.select_track(kind, track_id)?;
        let tracks = match kind {
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
                } => {
                    self.snapshot.duration_seconds = duration_seconds;
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
                    self.emit_state();
                }
                EngineEvent::PositionChanged(position) => {
                    self.snapshot.position_seconds = position;
                    self.persist_current_position()?;
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
                    self.snapshot.status = PlaybackStatus::Ended;
                    self.emit_state();
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
        if is_resumable(
            self.snapshot.duration_seconds,
            self.snapshot.position_seconds,
        ) {
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
        fn set_volume(&mut self, _: f64) -> Result<(), EngineError> {
            Ok(())
        }
        fn set_mute(&mut self, _: bool) -> Result<(), EngineError> {
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
        });
        let mut session = PlayerSession::new(engine, MemoryHistory { resume: Some(24.0) });

        session.open(&media_path).unwrap();
        session.poll().unwrap();
        let events = session.take_events();
        assert!(events.iter().any(|event| matches!(event, PlayerEvent::State { snapshot } if snapshot.status == PlaybackStatus::Playing && snapshot.position_seconds == 24.0)));
        fs::remove_dir_all(directory).unwrap();
    }
}
