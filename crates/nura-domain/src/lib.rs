use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const MINIMUM_RESUMABLE_DURATION_SECONDS: f64 = 60.0;
pub const RESUME_END_GUARD_SECONDS: f64 = 30.0;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MediaItem {
    pub path: PathBuf,
    pub title: String,
}

impl MediaItem {
    pub fn from_path(path: impl Into<PathBuf>) -> Result<Self, DomainError> {
        let path = path.into();
        if !path.is_file() {
            return Err(DomainError::MissingFile(path));
        }

        let title = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("Untitled media")
            .to_owned();
        Ok(Self { path, title })
    }

    pub fn path_key(&self) -> String {
        self.path.to_string_lossy().into_owned()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackStatus {
    Empty,
    Loading,
    Playing,
    Paused,
    Ended,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrackKind {
    Audio,
    Subtitle,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Track {
    pub id: i64,
    pub kind: TrackKind,
    pub title: Option<String>,
    pub language: Option<String>,
    pub external: bool,
    pub selected: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PlaybackSnapshot {
    pub item: Option<MediaItem>,
    pub status: PlaybackStatus,
    pub position_seconds: f64,
    pub duration_seconds: Option<f64>,
    pub volume: f64,
    pub muted: bool,
    pub audio_tracks: Vec<Track>,
    pub subtitle_tracks: Vec<Track>,
    pub error: Option<String>,
}

impl Default for PlaybackSnapshot {
    fn default() -> Self {
        Self {
            item: None,
            status: PlaybackStatus::Empty,
            position_seconds: 0.0,
            duration_seconds: None,
            volume: 100.0,
            muted: false,
            audio_tracks: Vec::new(),
            subtitle_tracks: Vec::new(),
            error: None,
        }
    }
}

pub fn is_resumable(duration_seconds: Option<f64>, position_seconds: f64) -> bool {
    let Some(duration_seconds) = duration_seconds else {
        return false;
    };
    duration_seconds >= MINIMUM_RESUMABLE_DURATION_SECONDS
        && position_seconds > 0.0
        && position_seconds < duration_seconds - RESUME_END_GUARD_SECONDS
}

pub fn same_name_subtitle(path: &Path) -> Option<PathBuf> {
    let stem = path.file_stem()?.to_str()?;
    let parent = path.parent()?;
    ["srt", "ass", "ssa", "vtt"]
        .iter()
        .map(|extension| parent.join(format!("{stem}.{extension}")))
        .find(|candidate| candidate.is_file())
}

#[derive(Debug, Error)]
pub enum DomainError {
    #[error("The media file no longer exists: {0}")]
    MissingFile(PathBuf),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resume_policy_excludes_short_media_and_the_end_credits() {
        assert!(!is_resumable(Some(59.0), 20.0));
        assert!(is_resumable(Some(120.0), 20.0));
        assert!(!is_resumable(Some(120.0), 95.0));
    }
}
