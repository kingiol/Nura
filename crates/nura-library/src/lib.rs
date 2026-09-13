use std::path::Path;
use std::time::Duration;

use nura_domain::{
    AnalysisKey, AnalysisRun, AnalysisStatus, HistoryEntry, InstantNote, MediaItem, MediaSource,
    NewInstantNote, TranscriptDocument, TranscriptSearchResult,
};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use thiserror::Error;

pub trait HistoryRepository: Send {
    fn resume_position(&mut self, item: &MediaItem) -> Result<Option<f64>, HistoryError>;
    fn remember(
        &mut self,
        item: &MediaItem,
        position_seconds: Option<f64>,
    ) -> Result<(), HistoryError>;
    fn clear_resume(&mut self, item: &MediaItem) -> Result<(), HistoryError>;
    fn recent_items(&mut self, limit: usize) -> Result<Vec<MediaItem>, HistoryError>;
    fn history_items(&mut self, limit: usize) -> Result<Vec<HistoryEntry>, HistoryError>;
    fn remove_history_item(&mut self, path_key: &str) -> Result<(), HistoryError>;
    fn clear_history(&mut self) -> Result<(), HistoryError>;
}

pub struct SqliteHistoryRepository {
    connection: Connection,
}

impl SqliteHistoryRepository {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, HistoryError> {
        let connection = Connection::open(path)?;
        connection.busy_timeout(Duration::from_secs(5))?;
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

    fn history_items(&mut self, limit: usize) -> Result<Vec<HistoryEntry>, HistoryError> {
        let mut statement = self.connection.prepare(
            "SELECT path, title, resume_seconds, opened_at
             FROM media_history
             ORDER BY opened_at DESC, rowid DESC
             LIMIT ?1",
        )?;
        let rows = statement.query_map(params![limit as i64], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<f64>>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })?;
        rows.map(|row| {
            let (path, title, resume_seconds, opened_at_seconds) = row?;
            let source = if path.starts_with("http://") || path.starts_with("https://") {
                MediaSource::PublicUrl(path)
            } else {
                MediaSource::LocalFile(path.into())
            };
            Ok(HistoryEntry {
                item: MediaItem { source, title },
                resume_seconds,
                opened_at_seconds,
            })
        })
        .collect::<Result<Vec<_>, rusqlite::Error>>()
        .map_err(HistoryError::Sqlite)
    }

    fn remove_history_item(&mut self, path_key: &str) -> Result<(), HistoryError> {
        self.connection.execute(
            "DELETE FROM media_history WHERE path = ?1",
            params![path_key],
        )?;
        Ok(())
    }

    fn clear_history(&mut self) -> Result<(), HistoryError> {
        self.connection.execute("DELETE FROM media_history", [])?;
        Ok(())
    }
}

#[derive(Debug, Error)]
pub enum HistoryError {
    #[error("No history entry exists")]
    NotFound,
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
}

pub trait AnalysisRepository: Send {
    fn complete_transcript(
        &mut self,
        key: &AnalysisKey,
    ) -> Result<Option<TranscriptDocument>, AnalysisError>;
    fn promote_transcript(&mut self, document: &TranscriptDocument) -> Result<(), AnalysisError>;
    fn search_transcript(
        &mut self,
        key: &AnalysisKey,
        query: &str,
        limit: usize,
    ) -> Result<Vec<TranscriptSearchResult>, AnalysisError>;
    fn save_run(&mut self, run: &AnalysisRun) -> Result<(), AnalysisError>;
    fn load_run(&mut self, key: &AnalysisKey) -> Result<Option<AnalysisRun>, AnalysisError>;
    fn delete_analysis(&mut self, key: &AnalysisKey) -> Result<(), AnalysisError>;
    fn create_note(&mut self, note: &NewInstantNote) -> Result<InstantNote, AnalysisError>;
    fn update_note(&mut self, note: &InstantNote) -> Result<(), AnalysisError>;
    fn delete_note(&mut self, id: i64) -> Result<InstantNote, AnalysisError>;
}

pub struct SqliteAnalysisRepository {
    connection: Connection,
}

impl SqliteAnalysisRepository {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, AnalysisError> {
        let connection = Connection::open(path)?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS transcripts (
                media_fingerprint TEXT NOT NULL,
                source_fingerprint TEXT NOT NULL,
                analysis_profile TEXT NOT NULL,
                source TEXT NOT NULL,
                provider_id TEXT,
                model_revision TEXT,
                PRIMARY KEY (media_fingerprint, source_fingerprint, analysis_profile)
            );
            CREATE TABLE IF NOT EXISTS transcript_segments (
                media_fingerprint TEXT NOT NULL,
                source_fingerprint TEXT NOT NULL,
                analysis_profile TEXT NOT NULL,
                segment_index INTEGER NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                text TEXT NOT NULL,
                PRIMARY KEY (
                    media_fingerprint,
                    source_fingerprint,
                    analysis_profile,
                    segment_index
                )
            );
            CREATE INDEX IF NOT EXISTS transcript_segments_key ON transcript_segments (
                media_fingerprint,
                source_fingerprint,
                analysis_profile,
                segment_index
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(
                media_fingerprint UNINDEXED,
                source_fingerprint UNINDEXED,
                analysis_profile UNINDEXED,
                segment_index UNINDEXED,
                text
            );
            CREATE TABLE IF NOT EXISTS analysis_runs (
                media_fingerprint TEXT NOT NULL,
                source_fingerprint TEXT NOT NULL,
                analysis_profile TEXT NOT NULL,
                total_chunks INTEGER NOT NULL,
                completed_chunk_indexes_json TEXT NOT NULL,
                status TEXT NOT NULL,
                last_error TEXT,
                PRIMARY KEY (media_fingerprint, source_fingerprint, analysis_profile)
            );
            CREATE TABLE IF NOT EXISTS instant_notes (
                id INTEGER PRIMARY KEY,
                media_fingerprint TEXT NOT NULL,
                position_ms INTEGER NOT NULL,
                media_title TEXT NOT NULL,
                transcript_quote TEXT,
                screenshot_reference TEXT,
                body TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS instant_notes_media ON instant_notes (
                media_fingerprint,
                position_ms
            );
            ",
        )?;
        Ok(Self { connection })
    }
}

impl AnalysisRepository for SqliteAnalysisRepository {
    fn complete_transcript(
        &mut self,
        key: &AnalysisKey,
    ) -> Result<Option<TranscriptDocument>, AnalysisError> {
        let metadata = self
            .connection
            .query_row(
                "
                SELECT t.source, t.provider_id, t.model_revision
                FROM transcripts t
                INNER JOIN analysis_runs r
                    ON r.media_fingerprint = t.media_fingerprint
                    AND r.source_fingerprint = t.source_fingerprint
                    AND r.analysis_profile = t.analysis_profile
                WHERE t.media_fingerprint = ?1
                    AND t.source_fingerprint = ?2
                    AND t.analysis_profile = ?3
                    AND r.status IN ('complete', 'low_quality')
                ",
                key_params(key),
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                },
            )
            .optional()?;

        let Some((source, provider_id, model_revision)) = metadata else {
            return Ok(None);
        };

        let mut statement = self.connection.prepare(
            "
            SELECT start_ms, end_ms, text
            FROM transcript_segments
            WHERE media_fingerprint = ?1
                AND source_fingerprint = ?2
                AND analysis_profile = ?3
            ORDER BY segment_index ASC
            ",
        )?;
        let segments = statement
            .query_map(key_params(key), |row| {
                Ok(nura_domain::TranscriptSegment {
                    start_ms: row.get(0)?,
                    end_ms: row.get(1)?,
                    text: row.get(2)?,
                })
            })?
            .collect::<Result<Vec<_>, rusqlite::Error>>()?;

        Ok(Some(TranscriptDocument {
            key: key.clone(),
            source,
            provider_id,
            model_revision,
            segments,
        }))
    }

    fn promote_transcript(&mut self, document: &TranscriptDocument) -> Result<(), AnalysisError> {
        validate_document(document)?;

        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let key = &document.key;
        transaction.execute("DELETE FROM transcript_fts WHERE media_fingerprint = ?1 AND source_fingerprint = ?2 AND analysis_profile = ?3", key_params(key))?;
        transaction.execute("DELETE FROM transcript_segments WHERE media_fingerprint = ?1 AND source_fingerprint = ?2 AND analysis_profile = ?3", key_params(key))?;
        transaction.execute(
            "
            INSERT INTO transcripts (
                media_fingerprint,
                source_fingerprint,
                analysis_profile,
                source,
                provider_id,
                model_revision
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(media_fingerprint, source_fingerprint, analysis_profile) DO UPDATE SET
                source = excluded.source,
                provider_id = excluded.provider_id,
                model_revision = excluded.model_revision
            ",
            params![
                key.media_fingerprint,
                key.source_fingerprint,
                key.analysis_profile,
                document.source,
                document.provider_id,
                document.model_revision,
            ],
        )?;

        for (segment_index, segment) in document.segments.iter().enumerate() {
            transaction.execute(
                "
                INSERT INTO transcript_segments (
                    media_fingerprint,
                    source_fingerprint,
                    analysis_profile,
                    segment_index,
                    start_ms,
                    end_ms,
                    text
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                ",
                params![
                    key.media_fingerprint,
                    key.source_fingerprint,
                    key.analysis_profile,
                    segment_index as i64,
                    segment.start_ms,
                    segment.end_ms,
                    segment.text,
                ],
            )?;
            transaction.execute(
                "
                INSERT INTO transcript_fts (
                    media_fingerprint,
                    source_fingerprint,
                    analysis_profile,
                    segment_index,
                    text
                ) VALUES (?1, ?2, ?3, ?4, ?5)
                ",
                params![
                    key.media_fingerprint,
                    key.source_fingerprint,
                    key.analysis_profile,
                    segment_index as i64,
                    segment.text,
                ],
            )?;
        }

        transaction.execute(
            "
            INSERT INTO analysis_runs (
                media_fingerprint,
                source_fingerprint,
                analysis_profile,
                total_chunks,
                completed_chunk_indexes_json,
                status,
                last_error
            ) VALUES (?1, ?2, ?3, 0, '[]', 'complete', NULL)
            ON CONFLICT(media_fingerprint, source_fingerprint, analysis_profile) DO UPDATE SET
                status = 'complete',
                last_error = NULL
            ",
            key_params(key),
        )?;
        transaction.commit()?;
        Ok(())
    }

    fn search_transcript(
        &mut self,
        key: &AnalysisKey,
        query: &str,
        limit: usize,
    ) -> Result<Vec<TranscriptSearchResult>, AnalysisError> {
        if query.trim().is_empty() || limit == 0 {
            return Ok(Vec::new());
        }
        let match_query = fts_match_query(query);

        let mut statement = self.connection.prepare(
            "
            SELECT s.start_ms, s.end_ms, s.text
            FROM transcript_fts f
            INNER JOIN transcript_segments s
                ON s.media_fingerprint = f.media_fingerprint
                AND s.source_fingerprint = f.source_fingerprint
                AND s.analysis_profile = f.analysis_profile
                AND s.segment_index = f.segment_index
            WHERE f.media_fingerprint = ?1
                AND f.source_fingerprint = ?2
                AND f.analysis_profile = ?3
                AND transcript_fts MATCH ?4
            ORDER BY rank
            LIMIT ?5
            ",
        )?;
        let rows = statement.query_map(
            params![
                key.media_fingerprint,
                key.source_fingerprint,
                key.analysis_profile,
                match_query,
                limit as i64,
            ],
            |row| {
                Ok(TranscriptSearchResult {
                    start_ms: row.get(0)?,
                    end_ms: row.get(1)?,
                    text: row.get(2)?,
                })
            },
        )?;
        rows.collect::<Result<Vec<_>, rusqlite::Error>>()
            .map_err(AnalysisError::Sqlite)
    }

    fn save_run(&mut self, run: &AnalysisRun) -> Result<(), AnalysisError> {
        validate_run(run)?;
        let completed_chunk_indexes_json = serde_json::to_string(&run.completed_chunk_indexes)?;
        self.connection.execute(
            "
            INSERT INTO analysis_runs (
                media_fingerprint,
                source_fingerprint,
                analysis_profile,
                total_chunks,
                completed_chunk_indexes_json,
                status,
                last_error
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(media_fingerprint, source_fingerprint, analysis_profile) DO UPDATE SET
                total_chunks = excluded.total_chunks,
                completed_chunk_indexes_json = excluded.completed_chunk_indexes_json,
                status = excluded.status,
                last_error = excluded.last_error
            ",
            params![
                run.key.media_fingerprint,
                run.key.source_fingerprint,
                run.key.analysis_profile,
                run.total_chunks,
                completed_chunk_indexes_json,
                run.status.as_str(),
                run.last_error,
            ],
        )?;
        Ok(())
    }

    fn load_run(&mut self, key: &AnalysisKey) -> Result<Option<AnalysisRun>, AnalysisError> {
        let row = self
            .connection
            .query_row(
                "
                SELECT total_chunks, completed_chunk_indexes_json, status, last_error
                FROM analysis_runs
                WHERE media_fingerprint = ?1
                    AND source_fingerprint = ?2
                    AND analysis_profile = ?3
                ",
                key_params(key),
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                    ))
                },
            )
            .optional()?;
        let Some((total_chunks, completed_chunk_indexes_json, status, last_error)) = row else {
            return Ok(None);
        };
        let completed_chunk_indexes = serde_json::from_str(&completed_chunk_indexes_json)?;
        let status = AnalysisStatus::from_str(&status).ok_or_else(|| {
            AnalysisError::InvalidData(format!("unknown analysis status: {status}"))
        })?;

        Ok(Some(AnalysisRun {
            key: key.clone(),
            total_chunks,
            completed_chunk_indexes,
            status,
            last_error,
        }))
    }

    fn delete_analysis(&mut self, key: &AnalysisKey) -> Result<(), AnalysisError> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute("DELETE FROM transcript_fts WHERE media_fingerprint = ?1 AND source_fingerprint = ?2 AND analysis_profile = ?3", key_params(key))?;
        transaction.execute("DELETE FROM transcript_segments WHERE media_fingerprint = ?1 AND source_fingerprint = ?2 AND analysis_profile = ?3", key_params(key))?;
        transaction.execute("DELETE FROM transcripts WHERE media_fingerprint = ?1 AND source_fingerprint = ?2 AND analysis_profile = ?3", key_params(key))?;
        transaction.execute("DELETE FROM analysis_runs WHERE media_fingerprint = ?1 AND source_fingerprint = ?2 AND analysis_profile = ?3", key_params(key))?;
        transaction.commit()?;
        Ok(())
    }

    fn create_note(&mut self, note: &NewInstantNote) -> Result<InstantNote, AnalysisError> {
        validate_new_note(note)?;
        let now = current_time_ms()?;
        self.connection.execute(
            "
            INSERT INTO instant_notes (
                media_fingerprint,
                position_ms,
                media_title,
                transcript_quote,
                screenshot_reference,
                body,
                created_at_ms,
                updated_at_ms
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ",
            params![
                note.media_fingerprint,
                note.position_ms,
                note.media_title,
                note.transcript_quote,
                note.screenshot_reference,
                note.body,
                now,
                now,
            ],
        )?;
        Ok(InstantNote {
            id: self.connection.last_insert_rowid(),
            media_fingerprint: note.media_fingerprint.clone(),
            position_ms: note.position_ms,
            media_title: note.media_title.clone(),
            transcript_quote: note.transcript_quote.clone(),
            screenshot_reference: note.screenshot_reference.clone(),
            body: note.body.clone(),
            created_at_ms: now,
            updated_at_ms: now,
        })
    }

    fn update_note(&mut self, note: &InstantNote) -> Result<(), AnalysisError> {
        validate_note(note)?;
        let affected = self.connection.execute(
            "
            UPDATE instant_notes
            SET media_fingerprint = ?1,
                position_ms = ?2,
                media_title = ?3,
                transcript_quote = ?4,
                screenshot_reference = ?5,
                body = ?6,
                updated_at_ms = ?7
            WHERE id = ?8
            ",
            params![
                note.media_fingerprint,
                note.position_ms,
                note.media_title,
                note.transcript_quote,
                note.screenshot_reference,
                note.body,
                note.updated_at_ms,
                note.id,
            ],
        )?;
        if affected == 0 {
            return Err(AnalysisError::NotFound("instant note"));
        }
        Ok(())
    }

    fn delete_note(&mut self, id: i64) -> Result<InstantNote, AnalysisError> {
        let note = self
            .connection
            .query_row(
                "
                SELECT id, media_fingerprint, position_ms, media_title, transcript_quote,
                    screenshot_reference, body, created_at_ms, updated_at_ms
                FROM instant_notes
                WHERE id = ?1
                ",
                params![id],
                |row| {
                    Ok(InstantNote {
                        id: row.get(0)?,
                        media_fingerprint: row.get(1)?,
                        position_ms: row.get(2)?,
                        media_title: row.get(3)?,
                        transcript_quote: row.get(4)?,
                        screenshot_reference: row.get(5)?,
                        body: row.get(6)?,
                        created_at_ms: row.get(7)?,
                        updated_at_ms: row.get(8)?,
                    })
                },
            )
            .optional()?
            .ok_or(AnalysisError::NotFound("instant note"))?;
        self.connection
            .execute("DELETE FROM instant_notes WHERE id = ?1", params![id])?;
        Ok(note)
    }
}

fn key_params(key: &AnalysisKey) -> [&str; 3] {
    [
        &key.media_fingerprint,
        &key.source_fingerprint,
        &key.analysis_profile,
    ]
}

fn fts_match_query(query: &str) -> String {
    query
        .split_whitespace()
        .map(|term| format!("\"{}\"", term.replace('"', "\"\"")))
        .collect::<Vec<_>>()
        .join(" AND ")
}

fn validate_document(document: &TranscriptDocument) -> Result<(), AnalysisError> {
    validate_key(&document.key)?;
    if document.source.trim().is_empty() {
        return Err(AnalysisError::InvalidData(
            "transcript source is empty".to_owned(),
        ));
    }
    if document.segments.is_empty() {
        return Err(AnalysisError::InvalidData(
            "transcript must contain at least one segment".to_owned(),
        ));
    }
    for segment in &document.segments {
        if segment.start_ms < 0 || segment.end_ms <= segment.start_ms {
            return Err(AnalysisError::InvalidData(
                "transcript segment has an invalid time range".to_owned(),
            ));
        }
        if segment.text.trim().is_empty() {
            return Err(AnalysisError::InvalidData(
                "transcript segment text is empty".to_owned(),
            ));
        }
    }
    Ok(())
}

fn validate_run(run: &AnalysisRun) -> Result<(), AnalysisError> {
    validate_key(&run.key)?;
    if run.total_chunks < 0 {
        return Err(AnalysisError::InvalidData(
            "analysis run total chunks is negative".to_owned(),
        ));
    }
    if run
        .completed_chunk_indexes
        .iter()
        .any(|index| *index < 0 || *index >= run.total_chunks)
    {
        return Err(AnalysisError::InvalidData(
            "analysis run has an invalid completed chunk index".to_owned(),
        ));
    }
    Ok(())
}

fn validate_new_note(note: &NewInstantNote) -> Result<(), AnalysisError> {
    if note.media_fingerprint.trim().is_empty() || note.media_title.trim().is_empty() {
        return Err(AnalysisError::InvalidData(
            "instant note media identity is empty".to_owned(),
        ));
    }
    if note.position_ms < 0 {
        return Err(AnalysisError::InvalidData(
            "instant note position is negative".to_owned(),
        ));
    }
    Ok(())
}

fn validate_note(note: &InstantNote) -> Result<(), AnalysisError> {
    if note.id <= 0 || note.created_at_ms < 0 || note.updated_at_ms < note.created_at_ms {
        return Err(AnalysisError::InvalidData(
            "instant note has invalid identity or timestamps".to_owned(),
        ));
    }
    validate_new_note(&NewInstantNote {
        media_fingerprint: note.media_fingerprint.clone(),
        position_ms: note.position_ms,
        media_title: note.media_title.clone(),
        transcript_quote: note.transcript_quote.clone(),
        screenshot_reference: note.screenshot_reference.clone(),
        body: note.body.clone(),
    })
}

fn validate_key(key: &AnalysisKey) -> Result<(), AnalysisError> {
    if key.media_fingerprint.trim().is_empty()
        || key.source_fingerprint.trim().is_empty()
        || key.analysis_profile.trim().is_empty()
    {
        return Err(AnalysisError::InvalidData(
            "analysis key contains an empty value".to_owned(),
        ));
    }
    Ok(())
}

fn current_time_ms() -> Result<i64, AnalysisError> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| AnalysisError::InvalidData(format!("system clock is invalid: {error}")))?
        .as_millis()
        .try_into()
        .map_err(|_| {
            AnalysisError::InvalidData("system clock exceeds i64 milliseconds".to_owned())
        })?)
}

#[derive(Debug, Error)]
pub enum AnalysisError {
    #[error("Analysis record not found: {0}")]
    NotFound(&'static str),
    #[error("Invalid analysis data: {0}")]
    InvalidData(String),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn complete_transcript_is_reused_only_for_the_same_cache_key() {
        let directory = test_directory("analysis-cache-key");
        let mut repository =
            SqliteAnalysisRepository::open(directory.join("analysis.sqlite")).unwrap();
        let key = AnalysisKey::new("media-a", "subtitle-a", "subtitle/srt-v1");

        repository
            .promote_transcript(&document(key.clone(), "first"))
            .unwrap();

        assert!(repository.complete_transcript(&key).unwrap().is_some());
        assert!(
            repository
                .complete_transcript(&AnalysisKey::new(
                    "media-a",
                    "subtitle-b",
                    "subtitle/srt-v1",
                ))
                .unwrap()
                .is_none()
        );

        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn deleting_analysis_keeps_user_notes() {
        let directory = test_directory("analysis-delete");
        let mut repository =
            SqliteAnalysisRepository::open(directory.join("analysis.sqlite")).unwrap();
        let key = AnalysisKey::new("media-a", "subtitle-a", "subtitle/srt-v1");
        repository
            .promote_transcript(&document(key.clone(), "first"))
            .unwrap();
        let note = repository
            .create_note(&NewInstantNote {
                media_fingerprint: "media-a".to_owned(),
                position_ms: 1_000,
                media_title: "Example".to_owned(),
                transcript_quote: Some("first".to_owned()),
                screenshot_reference: None,
                body: "Remember this".to_owned(),
            })
            .unwrap();

        repository.delete_analysis(&key).unwrap();

        assert!(repository.complete_transcript(&key).unwrap().is_none());
        assert_eq!(repository.delete_note(note.id).unwrap(), note);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn transcript_search_returns_matching_segment_timestamps() {
        let directory = test_directory("analysis-search");
        let mut repository =
            SqliteAnalysisRepository::open(directory.join("analysis.sqlite")).unwrap();
        let key = AnalysisKey::new("media-a", "subtitle-a", "subtitle/srt-v1");
        repository
            .promote_transcript(&TranscriptDocument {
                key: key.clone(),
                source: "external_subtitle".to_owned(),
                provider_id: None,
                model_revision: None,
                segments: vec![nura_domain::TranscriptSegment {
                    start_ms: 4_000,
                    end_ms: 8_000,
                    text: "Rust ownership rules".to_owned(),
                }],
            })
            .unwrap();

        assert_eq!(
            repository.search_transcript(&key, "ownership", 10).unwrap(),
            vec![TranscriptSearchResult {
                start_ms: 4_000,
                end_ms: 8_000,
                text: "Rust ownership rules".to_owned(),
            }]
        );

        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn no_content_run_is_saved_and_loaded_as_a_terminal_state() {
        let directory = test_directory("analysis-run");
        let mut repository =
            SqliteAnalysisRepository::open(directory.join("analysis.sqlite")).unwrap();
        let run = AnalysisRun {
            key: AnalysisKey::new("media-a", "audio-v1", "groq/whisper-large-v3-turbo/segment"),
            total_chunks: 0,
            completed_chunk_indexes: Vec::new(),
            status: AnalysisStatus::NoContent,
            last_error: Some("No readable audio track".to_owned()),
        };

        repository.save_run(&run).unwrap();

        assert_eq!(repository.load_run(&run.key).unwrap(), Some(run));
        fs::remove_dir_all(directory).unwrap();
    }

    fn document(key: AnalysisKey, text: &str) -> TranscriptDocument {
        TranscriptDocument {
            key,
            source: "external_subtitle".to_owned(),
            provider_id: None,
            model_revision: None,
            segments: vec![nura_domain::TranscriptSegment {
                start_ms: 1_000,
                end_ms: 2_000,
                text: text.to_owned(),
            }],
        }
    }

    fn test_directory(name: &str) -> std::path::PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "nura-library-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
        ));
        fs::create_dir_all(&directory).unwrap();
        directory
    }

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

    #[test]
    fn lists_and_removes_history_entries() {
        let directory =
            std::env::temp_dir().join(format!("nura-history-test-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let media_path = directory.join("example.mp4");
        fs::write(&media_path, []).unwrap();
        let item = MediaItem::from_path(&media_path).unwrap();
        let mut history = SqliteHistoryRepository::open(directory.join("history.sqlite")).unwrap();

        history.remember(&item, Some(42.0)).unwrap();
        let entries = history.history_items(10).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].item, item);
        assert_eq!(entries[0].resume_seconds, Some(42.0));

        history
            .remove_history_item(&entries[0].item.path_key())
            .unwrap();
        assert!(history.history_items(10).unwrap().is_empty());
        history.clear_history().unwrap();
        fs::remove_dir_all(directory).unwrap();
    }
}
