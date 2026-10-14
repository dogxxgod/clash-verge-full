//! App distribution on mobile happens through the store/APK; in-app updates are unavailable.

use crate::singleton;
use anyhow::Result;

pub struct SilentUpdater;

singleton!(SilentUpdater, SILENT_UPDATER);

impl SilentUpdater {
    const fn new() -> Self {
        Self
    }

    pub fn is_update_ready(&self) -> bool {
        false
    }

    pub async fn try_install_on_startup(&self, _app_handle: &tauri::AppHandle) -> bool {
        false
    }

    pub async fn install_update(
        &self,
        _app_handle: &tauri::AppHandle,
        _version: &str,
        _on_event: impl Fn(DownloadEvent) + Sync,
    ) -> Result<bool> {
        Err(anyhow::anyhow!("in-app updates are not supported on this platform"))
    }

    pub fn cancel_download(&self) {}

    pub fn discard_pending(&self) {}

    pub async fn start_background_check(&self, _app_handle: tauri::AppHandle) {}
}

/// Same wire shape as the updater plugin's JS `DownloadEvent`.
#[derive(Clone, serde::Serialize, specta::Type)]
#[serde(tag = "event", content = "data")]
pub enum DownloadEvent {
    #[serde(rename_all = "camelCase")]
    Started {
        content_length: Option<u64>,
    },
    #[serde(rename_all = "camelCase")]
    Progress {
        chunk_length: usize,
    },
    Finished,
}
