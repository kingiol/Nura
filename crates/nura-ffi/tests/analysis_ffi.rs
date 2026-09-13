use std::ffi::{CStr, CString};
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use nura_domain::TranscriptSearchResult;
use nura_ffi::{
    NuraPlayer, nura_analysis_load_json, nura_analysis_promote_json, nura_analysis_search_json,
    nura_player_create, nura_player_destroy, nura_string_free,
};
use serde_json::json;

static NEXT_DIRECTORY_ID: AtomicU64 = AtomicU64::new(0);

struct TestPlayer {
    player: *mut NuraPlayer,
    directory: std::path::PathBuf,
}

impl TestPlayer {
    fn create() -> Self {
        let directory = std::env::temp_dir().join(format!(
            "nura-analysis-ffi-{}-{}",
            std::process::id(),
            NEXT_DIRECTORY_ID.fetch_add(1, Ordering::Relaxed),
        ));
        fs::create_dir_all(&directory).expect("test state directory should be created");
        let directory_value = CString::new(directory.to_string_lossy().into_owned())
            .expect("test directory should not contain a NUL byte");
        let startup_options = CString::new("{}").expect("startup options should be valid");
        let player = nura_player_create(directory_value.as_ptr(), startup_options.as_ptr());
        assert!(!player.is_null(), "player should be created");
        Self { player, directory }
    }
}

impl Drop for TestPlayer {
    fn drop(&mut self) {
        unsafe { nura_player_destroy(self.player) };
        std::thread::sleep(Duration::from_millis(50));
        let _ = fs::remove_dir_all(&self.directory);
    }
}

fn json_query(player: *mut NuraPlayer, input: serde_json::Value) -> String {
    let input = CString::new(input.to_string()).expect("query input should be valid");
    let response = unsafe { nura_analysis_search_json(player, input.as_ptr()) };
    assert!(!response.is_null(), "analysis search should return JSON");
    let value = unsafe { CStr::from_ptr(response) }
        .to_str()
        .expect("response should be UTF-8")
        .to_owned();
    unsafe { nura_string_free(response) };
    value
}

fn json_load(player: *mut NuraPlayer, input: serde_json::Value) -> String {
    let input = CString::new(input.to_string()).expect("query input should be valid");
    let response = unsafe { nura_analysis_load_json(player, input.as_ptr()) };
    assert!(!response.is_null(), "analysis load should return JSON");
    let value = unsafe { CStr::from_ptr(response) }
        .to_str()
        .expect("response should be UTF-8")
        .to_owned();
    unsafe { nura_string_free(response) };
    value
}

#[test]
fn analysis_ffi_promotes_then_searches_segments() {
    let player = TestPlayer::create();
    let key = json!({
        "media_fingerprint": "media-a",
        "source_fingerprint": "subtitle-a",
        "analysis_profile": "subtitle/srt-v1"
    });
    assert_eq!(json_load(player.player, key.clone()), "null");
    let document = json!({
        "key": key,
        "source": "local_subtitle",
        "provider_id": null,
        "model_revision": null,
        "segments": [{
            "start_ms": 4_000,
            "end_ms": 8_000,
            "text": "Rust ownership"
        }]
    });
    let input = CString::new(document.to_string()).expect("document JSON should be valid");

    assert_eq!(
        unsafe { nura_analysis_promote_json(player.player, input.as_ptr()) },
        0
    );

    let results: Vec<TranscriptSearchResult> = serde_json::from_str(&json_query(
        player.player,
        json!({
            "key": {
                "media_fingerprint": "media-a",
                "source_fingerprint": "subtitle-a",
                "analysis_profile": "subtitle/srt-v1"
            },
            "query": "ownership",
            "limit": 10
        }),
    ))
    .expect("search response should decode");

    assert_eq!(results[0].start_ms, 4_000);
}
