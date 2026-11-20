//! Flat DTOs shared across the bridge.

use crate::core::config::Preferences;
use crate::core::upload::{CoreSummary, CoreUploadEvent, CoreUploadResult};

pub struct AppSettings {
    pub proxy: String,
    pub use_quota: bool,
    pub saver: bool,
    pub recursive: bool,
    pub force_upload: bool,
    pub pair_live_photos: bool,
    pub skip_incomplete_live_photos: bool,
    pub update_existing_photos_to_live: bool,
    pub upload_threads: i32,
    pub delete_from_host: bool,
    pub disable_unsupported_files_filter: bool,
    pub set_date_from_filename: bool,
    pub exclude_pattern: String,
}

impl From<Preferences> for AppSettings {
    fn from(p: Preferences) -> Self {
        Self {
            proxy: p.proxy,
            use_quota: p.use_quota,
            saver: p.saver,
            recursive: p.recursive,
            force_upload: p.force_upload,
            pair_live_photos: p.pair_live_photos,
            skip_incomplete_live_photos: p.skip_incomplete_live_photos,
            update_existing_photos_to_live: p.update_existing_photos_to_live,
            upload_threads: p.upload_threads,
            delete_from_host: p.delete_from_host,
            disable_unsupported_files_filter: p.disable_unsupported_files_filter,
            set_date_from_filename: p.set_date_from_filename,
            exclude_pattern: p.exclude_pattern,
        }
    }
}

impl AppSettings {
    pub fn into_core(self) -> Preferences {
        Preferences {
            proxy: self.proxy,
            use_quota: self.use_quota,
            saver: self.saver,
            recursive: self.recursive,
            force_upload: self.force_upload,
            pair_live_photos: self.pair_live_photos,
            skip_incomplete_live_photos: self.skip_incomplete_live_photos,
            update_existing_photos_to_live: self.update_existing_photos_to_live,
            upload_threads: self.upload_threads,
            delete_from_host: self.delete_from_host,
            disable_unsupported_files_filter: self.disable_unsupported_files_filter,
            set_date_from_filename: self.set_date_from_filename,
            exclude_pattern: self.exclude_pattern,
        }
    }
}

pub struct AccountInfo {
    pub email: String,
    pub needs_token_binding: bool,
}

pub struct UploadEvent {
    pub event_type: String,
    pub worker_id: i32,
    pub status: String,
    pub file_path: String,
    pub file_name: String,
    pub message: String,
    pub bytes_uploaded: i64,
    pub bytes_total: i64,
    pub attempt: i32,
    pub total: i32,
    pub media_key: String,
    pub is_error: bool,
    pub skipped: bool,
    pub skip_code: String,
    pub skip_reason: String,
}

impl From<CoreUploadEvent> for UploadEvent {
    fn from(e: CoreUploadEvent) -> Self {
        Self {
            event_type: e.event_type,
            worker_id: e.worker_id,
            status: e.status,
            file_path: e.file_path,
            file_name: e.file_name,
            message: e.message,
            bytes_uploaded: e.bytes_uploaded,
            bytes_total: e.bytes_total,
            attempt: e.attempt,
            total: e.total,
            media_key: e.media_key,
            is_error: e.is_error,
            skipped: e.skipped,
            skip_code: e.skip_code,
            skip_reason: e.skip_reason,
        }
    }
}

pub struct UploadResult {
    pub path: String,
    pub media_key: String,
    pub is_error: bool,
    pub skipped: bool,
    pub skip_code: String,
    pub skip_reason: String,
    pub error_message: String,
}

impl From<CoreUploadResult> for UploadResult {
    fn from(r: CoreUploadResult) -> Self {
        Self {
            path: r.path,
            media_key: r.media_key,
            is_error: r.is_error,
            skipped: r.skipped,
            skip_code: r.skip_code,
            skip_reason: r.skip_reason,
            error_message: r.error_message,
        }
    }
}

pub struct UploadSummary {
    pub total: i32,
    pub succeeded: i32,
    pub failed: i32,
    pub skipped: i32,
    pub results: Vec<UploadResult>,
}

impl From<CoreSummary> for UploadSummary {
    fn from(s: CoreSummary) -> Self {
        Self {
            total: s.total,
            succeeded: s.succeeded,
            failed: s.failed,
            skipped: s.skipped,
            results: s.results.into_iter().map(UploadResult::from).collect(),
        }
    }
}

pub struct CoreInfo {
    pub crate_version: String,
    pub bridge_version: String,
    pub target: String,
    pub features: String,
}

pub struct FilePreview {
    pub path: String,
    pub size_bytes: i64,
}

pub struct UploadProgress {
    pub total_bytes: i64,
    pub uploaded_bytes: i64,
    pub elapsed_ms: i64,
    pub speed_bytes_per_sec: i64,
    pub eta_seconds: i64,
}

impl From<crate::core::upload::CoreUploadProgress> for UploadProgress {
    fn from(p: crate::core::upload::CoreUploadProgress) -> Self {
        Self {
            total_bytes: p.total_bytes,
            uploaded_bytes: p.uploaded_bytes,
            elapsed_ms: p.elapsed_ms,
            speed_bytes_per_sec: p.speed_bytes_per_sec,
            eta_seconds: p.eta_seconds,
        }
    }
}
