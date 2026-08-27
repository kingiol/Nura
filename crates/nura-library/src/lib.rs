use std::path::Path;

use nura_domain::MediaItem;
use rusqlite::{Connection, params};
use thiserror::Error;

#[derive(Clone, Debug, PartialEq)]
pub struct ResumeRecord {
    pub item: MediaItem,
    pub position_seconds: f64,
}

pub trait HistoryRepository: Send {
    fn resume_position(&mut self, item: &MediaItem) -> Result<Option<f64>, HistoryError>;
    fn remember(
        &mut self,
        item: &MediaItem,
        position_seconds: Option<f64>,
    ) -> Result<(), HistoryError>;
    fn clear_resume(&mut self, item: &MediaItem) -> Result<(), HistoryError>;
    fn recent_items(&mut self, limit: usize) -> Result<Vec<MediaItem>, HistoryError>;
}

pub struct SqliteHistoryRepository {
    connection: Connection,
}

impl SqliteHistoryRepository {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, HistoryError> {
        let connection = Connection::open(path)?;
        connection.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS media_history (
                path TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                resume_seconds REAL,
                opened_at INTEGER NOT NULL DEFAULT (unixepoch())
            );
            CREATE INDEX IF NOT EXISTS media_history_opened_at ON media_history(opened_at DESC);
            ",
        )?;
        Ok(Self { connection })
    }
}

impl HistoryRepository for SqliteHistoryRepository {
    fn resume_position(&mut self, item: &MediaItem) -> Result<Option<f64>, HistoryError> {
        self.connection
            .query_row(
                "SELECT resume_seconds FROM media_history WHERE path = ?1",
                params![item.path_key()],
                |row| row.get(0),
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => HistoryError::NotFound,
                other => HistoryError::Sqlite(other),
            })
            .or_else(|error| match error {
                HistoryError::NotFound => Ok(None),
                other => Err(other),
            })
    }

    fn remember(
        &mut self,
        item: &MediaItem,
        position_seconds: Option<f64>,
    ) -> Result<(), HistoryError> {
        self.connection.execute(
            "
            INSERT INTO media_history (path, title, resume_seconds, opened_at)
            VALUES (?1, ?2, ?3, unixepoch())
            ON CONFLICT(path) DO UPDATE SET
                title = excluded.title,
                resume_seconds = excluded.resume_seconds,
                opened_at = excluded.opened_at
            ",
            params![item.path_key(), item.title, position_seconds],
        )?;
        Ok(())
    }

    fn clear_resume(&mut self, item: &MediaItem) -> Result<(), HistoryError> {
        self.connection.execute(
            "UPDATE media_history SET resume_seconds = NULL WHERE path = ?1",
            params![item.path_key()],
        )?;
        Ok(())
    }

    fn recent_items(&mut self, limit: usize) -> Result<Vec<MediaItem>, HistoryError> {
        let mut statement = self.connection.prepare(
            "SELECT path, title FROM media_history ORDER BY opened_at DESC, rowid DESC LIMIT ?1",
        )?;
        let rows = statement.query_map(params![limit as i64], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        rows.map(|row| {
            let (path, title) = row?;
            let source = if path.starts_with("http://") || path.starts_with("https://") {
                nura_domain::MediaSource::PublicUrl(path)
            } else {
                nura_domain::MediaSource::LocalFile(path.into())
            };
            Ok(MediaItem { source, title })
        })
        .collect::<Result<Vec<_>, rusqlite::Error>>()
        .map_err(HistoryError::Sqlite)
    }
}

#[derive(Debug, Error)]
pub enum HistoryError {
    #[error("No history entry exists")]
    NotFound,
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn remembers_and_clears_a_resume_position() {
        let directory =
            std::env::temp_dir().join(format!("nura-library-test-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let media_path = directory.join("example.mp4");
        fs::write(&media_path, []).unwrap();
        let item = MediaItem::from_path(&media_path).unwrap();
        let mut history = SqliteHistoryRepository::open(directory.join("history.sqlite")).unwrap();

        history.remember(&item, Some(42.0)).unwrap();
        assert_eq!(history.resume_position(&item).unwrap(), Some(42.0));
        history.clear_resume(&item).unwrap();
        assert_eq!(history.resume_position(&item).unwrap(), None);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn returns_recent_items_in_open_order() {
        let directory =
            std::env::temp_dir().join(format!("nura-recent-test-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let first_path = directory.join("first.mp4");
        let second_path = directory.join("second.mp4");
        fs::write(&first_path, []).unwrap();
        fs::write(&second_path, []).unwrap();
        let mut history = SqliteHistoryRepository::open(directory.join("history.sqlite")).unwrap();
        history
            .remember(&MediaItem::from_path(&first_path).unwrap(), None)
            .unwrap();
        history
            .remember(&MediaItem::from_path(&second_path).unwrap(), None)
            .unwrap();
        let recent = history.recent_items(10).unwrap();
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0].title, "second.mp4");
        fs::remove_dir_all(directory).unwrap();
    }
}
