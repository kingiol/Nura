use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const MINIMUM_RESUMABLE_DURATION_SECONDS: f64 = 60.0;
pub const RESUME_END_GUARD_SECONDS: f64 = 30.0;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MediaItem {
    pub source: MediaSource,
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
        Ok(Self {
            source: MediaSource::LocalFile(path),
            title,
        })
    }

    pub fn from_url(url: impl Into<String>) -> Result<Self, DomainError> {
        let url = url.into();
        let trimmed = url.trim();
        let scheme = trimmed.split_once("://").map(|(scheme, _)| scheme);
        let valid_scheme = matches!(scheme, Some("http" | "https"));
        let has_host = trimmed
            .split_once("://")
            .map(|(_, rest)| !rest.split('/').next().unwrap_or_default().is_empty())
            .unwrap_or(false);
        if !valid_scheme || !has_host {
            return Err(DomainError::InvalidUrl(url));
        }

        let title = trimmed
            .trim_end_matches('/')
            .rsplit('/')
            .next()
            .filter(|value| !value.is_empty())
            .unwrap_or(trimmed)
            .split('?')
            .next()
            .unwrap_or(trimmed)
            .to_owned();
        Ok(Self {
            source: MediaSource::PublicUrl(trimmed.to_owned()),
            title,
        })
    }

    pub fn path_key(&self) -> String {
        self.source.key()
    }

    pub fn locator(&self) -> String {
        self.source.locator()
    }

    pub fn local_path(&self) -> Option<&Path> {
        match &self.source {
            MediaSource::LocalFile(path) => Some(path),
            MediaSource::PublicUrl(_) => None,
        }
    }

    pub fn is_local(&self) -> bool {
        matches!(self.source, MediaSource::LocalFile(_))
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum MediaSource {
    LocalFile(PathBuf),
    PublicUrl(String),
}

impl MediaSource {
    pub fn locator(&self) -> String {
        match self {
            MediaSource::LocalFile(path) => path.to_string_lossy().into_owned(),
            MediaSource::PublicUrl(url) => url.clone(),
        }
    }

    pub fn key(&self) -> String {
        self.locator()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackStatus {
    Empty,
    Loading,
    Buffering,
    Playing,
    Paused,
    Ended,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrackKind {
    Video,
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
pub struct Chapter {
    pub id: i64,
    pub title: String,
    pub start_seconds: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PlaybackSnapshot {
    pub item: Option<MediaItem>,
    pub playlist: Vec<MediaItem>,
    pub playlist_index: Option<usize>,
    pub chapters: Vec<Chapter>,
    pub status: PlaybackStatus,
    pub position_seconds: f64,
    pub duration_seconds: Option<f64>,
    pub speed: f64,
    pub audio_delay_seconds: f64,
    pub subtitle_delay_seconds: f64,
    pub buffering_percent: Option<f64>,
    pub volume: f64,
    pub muted: bool,
    pub video_tracks: Vec<Track>,
    pub audio_tracks: Vec<Track>,
    pub subtitle_tracks: Vec<Track>,
    pub error: Option<String>,
}

impl Default for PlaybackSnapshot {
    fn default() -> Self {
        Self {
            item: None,
            playlist: Vec::new(),
            playlist_index: None,
            chapters: Vec::new(),
            status: PlaybackStatus::Empty,
            position_seconds: 0.0,
            duration_seconds: None,
            speed: 1.0,
            audio_delay_seconds: 0.0,
            subtitle_delay_seconds: 0.0,
            buffering_percent: None,
            volume: 100.0,
            muted: false,
            video_tracks: Vec::new(),
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
    #[error("Unsupported media URL: {0}")]
    InvalidUrl(String),
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

    #[test]
    fn public_urls_are_accepted_and_use_a_stable_source_key() {
        let item = MediaItem::from_url("https://example.com/video.m3u8?token=abc").unwrap();
        assert!(!item.is_local());
        assert_eq!(item.locator(), "https://example.com/video.m3u8?token=abc");
        assert_eq!(item.title, "video.m3u8");
    }

    #[test]
    fn unsupported_url_schemes_are_rejected() {
        assert!(matches!(
            MediaItem::from_url("ftp://example.com/video"),
            Err(DomainError::InvalidUrl(_))
        ));
    }
}
