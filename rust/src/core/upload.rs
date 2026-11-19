//! Upload orchestration: discovery, hashing, dedup, worker pool and events.

use crate::core::api::Api;
use crate::core::config::{ConfigStore, Preferences};
use anyhow::{bail, Context, Result};
use futures::StreamExt;
use chrono::{Datelike, Local, NaiveDateTime, TimeZone};
use sha1::Digest;
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use std::sync::Mutex;
use tokio::sync::RwLock;

#[derive(Debug, Clone, Default)]
pub struct CoreUploadEvent {
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

#[derive(Debug, Clone, Default)]
pub struct CoreUploadResult {
    pub path: String,
    pub media_key: String,
    pub is_error: bool,
    pub skipped: bool,
    pub skip_code: String,
    pub skip_reason: String,
    pub error_message: String,
}

#[derive(Debug, Clone, Default)]
pub struct CoreSummary {
    pub total: i32,
    pub succeeded: i32,
    pub failed: i32,
    pub skipped: i32,
    pub results: Vec<CoreUploadResult>,
}

#[derive(Debug, Clone)]
pub struct UploadOptions {
    pub credential: String,
    pub proxy: String,
    pub saver: bool,
    pub use_quota: bool,
    pub recursive: bool,
    pub exclude_pattern: String,
    pub threads: usize,
    pub force_upload: bool,
    pub delete_from_host: bool,
    pub disable_unsupported_files_filter: bool,
    pub set_date_from_filename: bool,
    pub album_name: String,
    pub album_auto: bool,
}

impl UploadOptions {
    pub fn from_preferences(prefs: &Preferences, credential: String) -> Self {
        Self {
            credential,
            proxy: prefs.proxy.clone(),
            saver: prefs.saver,
            use_quota: prefs.use_quota,
            recursive: prefs.recursive,
            exclude_pattern: prefs.exclude_pattern.clone(),
            threads: prefs.upload_threads.max(1) as usize,
            force_upload: prefs.force_upload,
            delete_from_host: prefs.delete_from_host,
            disable_unsupported_files_filter: prefs.disable_unsupported_files_filter,
            set_date_from_filename: prefs.set_date_from_filename,
            album_name: String::new(),
            album_auto: false,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct CoreUploadProgress {
    pub total_bytes: i64,
    pub uploaded_bytes: i64,
    pub elapsed_ms: i64,
    pub speed_bytes_per_sec: i64,
    pub eta_seconds: i64,
}

#[derive(Debug, Clone, Default)]
pub struct CoreFilePreview {
    pub path: String,
    pub size_bytes: i64,
}

pub struct UploadState {
    pub events: Mutex<VecDeque<CoreUploadEvent>>,
    pub summary: RwLock<CoreSummary>,
    pub cancel: Mutex<Option<tokio_util::sync::CancellationToken>>,
    pub running: AtomicBool,
    started_at: Mutex<Option<Instant>>,
    total_bytes: AtomicI64,
    uploaded_bytes: AtomicI64,
}

impl Default for UploadState {
    fn default() -> Self {
        Self {
            events: Mutex::new(VecDeque::new()),
            summary: RwLock::new(CoreSummary::default()),
            cancel: Mutex::new(None),
            running: AtomicBool::new(false),
            started_at: Mutex::new(None),
            total_bytes: AtomicI64::new(0),
            uploaded_bytes: AtomicI64::new(0),
        }
    }
}

impl UploadState {
    fn emit(&self, event: CoreUploadEvent) {
        let mut events = self.events.lock().expect("event lock poisoned");
        if events.len() > 4096 {
            events.pop_front();
        }
        events.push_back(event);
    }

    pub fn emit_sync(&self, event: CoreUploadEvent) {
        self.emit(event);
    }

    pub fn drain_events(&self) -> Vec<CoreUploadEvent> {
        let mut events = self.events.lock().expect("event lock poisoned");
        events.drain(..).collect()
    }

    pub fn summary(&self) -> CoreSummary {
        self.summary.blocking_read().clone()
    }

    pub fn progress(&self) -> CoreUploadProgress {
        let total = self.total_bytes.load(Ordering::Acquire).max(0);
        let uploaded = self.uploaded_bytes.load(Ordering::Acquire).max(0);
        let elapsed_ms = self
            .started_at
            .lock()
            .expect("start lock poisoned")
            .map(|start| start.elapsed().as_millis() as i64)
            .unwrap_or(0);
        let speed = if elapsed_ms > 200 {
            uploaded.saturating_mul(1000) / elapsed_ms
        } else {
            0
        };
        let eta = if speed > 0 && total > uploaded {
            (total - uploaded) / speed
        } else {
            -1
        };
        CoreUploadProgress {
            total_bytes: total,
            uploaded_bytes: uploaded,
            elapsed_ms,
            speed_bytes_per_sec: speed,
            eta_seconds: eta,
        }
    }

    pub fn reset_progress(&self) {
        *self.started_at.lock().expect("start lock poisoned") = Some(Instant::now());
        self.total_bytes.store(0, Ordering::Release);
        self.uploaded_bytes.store(0, Ordering::Release);
    }

    pub fn set_total_bytes(&self, bytes: i64) {
        self.total_bytes.store(bytes.max(0), Ordering::Release);
    }

    pub fn add_uploaded_bytes(&self, bytes: i64) {
        self.uploaded_bytes.fetch_add(bytes.max(0), Ordering::AcqRel);
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Acquire)
    }

    pub fn cancel(&self) {
        let token = self.cancel.lock().expect("cancel lock poisoned").clone();
        if let Some(token) = token {
            token.cancel();
        }
    }
}

pub fn start_upload(
    state: Arc<UploadState>,
    store: Arc<ConfigStore>,
    paths: Vec<String>,
    options: UploadOptions,
) -> Result<()> {
    if state.is_running() {
        bail!("an upload is already running");
    }
    if paths.is_empty() {
        bail!("no paths selected");
    }
    Api::new(
        &options.credential,
        &options.proxy,
        options.saver,
        options.use_quota,
    )?;
    let token = tokio_util::sync::CancellationToken::new();
    *state.cancel.lock().expect("cancel lock poisoned") = Some(token.clone());
    *state.summary.blocking_write() = CoreSummary::default();
    state.reset_progress();
    state.events.lock().expect("event lock poisoned").clear();
    state.running.store(true, Ordering::Release);

    crate::core::runtime().spawn(async move {
        let result = run_upload(&state, store, paths, options, token).await;
        if let Err(err) = result {
            state.emit_sync(CoreUploadEvent {
                event_type: "fatal".into(),
                message: err.to_string(),
                is_error: true,
                ..Default::default()
            });
        }
        state.running.store(false, Ordering::Release);
        state.emit_sync(CoreUploadEvent {
            event_type: "stop".into(),
            ..Default::default()
        });
    });
    Ok(())
}

async fn run_upload(
    state: &Arc<UploadState>,
    store: Arc<ConfigStore>,
    paths: Vec<String>,
    options: UploadOptions,
    cancel: tokio_util::sync::CancellationToken,
) -> Result<()> {
    state.emit_sync(CoreUploadEvent {
        event_type: "start".into(),
        ..Default::default()
    });
    let files = discover_files(&paths, &options)?;
    let total_bytes: i64 = files.iter().filter_map(|p| std::fs::metadata(p).ok()).map(|m| m.len() as i64).sum();
    state.set_total_bytes(total_bytes);
    state.emit_sync(CoreUploadEvent {
        event_type: "start".into(),
        total: files.len() as i32,
        ..Default::default()
    });
    {
        let mut summary = state.summary.write().await;
        summary.total = files.len() as i32;
    }
    if files.is_empty() {
        return Ok(());
    }

    let worker_count = options.threads.max(1);
    let results: Vec<CoreUploadResult> = futures::stream::iter(files.into_iter().enumerate())
        .map(|(index, path)| {
            let worker = (index % worker_count) as i32;
            let options = options.clone();
            let state = state.clone();
            let cancel = cancel.clone();
            let _store = store.clone();
            async move {
                if cancel.is_cancelled() {
                    return CoreUploadResult::default();
                }
                let api = match Api::new(
                    &options.credential,
                    &options.proxy,
                    options.saver,
                    options.use_quota,
                ) {
                    Ok(api) => api,
                    Err(err) => {
                        return CoreUploadResult {
                            path: path.display().to_string(),
                            is_error: true,
                            error_message: err.to_string(),
                            ..Default::default()
                        }
                    }
                };
                        upload_single_file(&api, &path, &options, &state, worker, &cancel).await
            }
        })
        .buffer_unordered(options.threads)
        .collect()
        .await;

    let mut successful = HashMap::new();
    let mut summary = state.summary.write().await;
    for result in &results {
        if result.is_error {
            summary.failed += 1;
        } else if result.skipped {
            summary.skipped += 1;
        } else {
            summary.succeeded += 1;
            if !result.media_key.is_empty() {
                successful.insert(result.path.clone(), result.media_key.clone());
            }
        }
        if !result.is_error {
            let bytes = std::fs::metadata(&result.path).map(|m| m.len() as i64).unwrap_or(0);
            state.add_uploaded_bytes(bytes);
        }
        summary.results.push(result.clone());
        state.emit_sync(CoreUploadEvent {
            event_type: "file_result".into(),
            file_path: result.path.clone(),
            media_key: result.media_key.clone(),
            is_error: result.is_error,
            skipped: result.skipped,
            skip_code: result.skip_code.clone(),
            skip_reason: result.skip_reason.clone(),
            message: result.error_message.clone(),
            ..Default::default()
        });
    }
    drop(summary);

    if !successful.is_empty() && !cancel.is_cancelled() {
        let api = Api::new(
            &options.credential,
            &options.proxy,
            options.saver,
            options.use_quota,
        )?;
        if options.album_auto {
            let mut by_dir: HashMap<PathBuf, Vec<String>> = HashMap::new();
            for (path, key) in successful {
                let parent = Path::new(&path)
                    .parent()
                    .unwrap_or_else(|| Path::new("."))
                    .to_path_buf();
                by_dir.entry(parent).or_default().push(key);
            }
            for (dir, keys) in by_dir {
                let name = dir
                    .file_name()
                    .and_then(|s| s.to_str())
                    .filter(|s| !s.is_empty() && *s != ".")
                    .unwrap_or("Uploads")
                    .to_string();
                let result = api.create_album(&name, &keys).await;
                state.emit_sync(album_event(&name, result));
            }
        } else if !options.album_name.is_empty() {
            let keys: Vec<String> = successful.into_values().collect();
            let name = options.album_name.clone();
            let result = api.create_album(&name, &keys).await;
            state.emit_sync(album_event(&name, result));
        }
    }
    Ok(())
}

fn album_event(name: &str, result: Result<String>) -> CoreUploadEvent {
    match result {
        Ok(key) => CoreUploadEvent {
            event_type: "album".into(),
            message: name.into(),
            media_key: key,
            ..Default::default()
        },
        Err(err) => CoreUploadEvent {
            event_type: "album".into(),
            message: name.into(),
            is_error: true,
            skip_reason: err.to_string(),
            ..Default::default()
        },
    }
}

async fn upload_single_file(
    api: &Api,
    path: &Path,
    options: &UploadOptions,
    state: &Arc<UploadState>,
    worker: i32,
    cancel: &tokio_util::sync::CancellationToken,
) -> CoreUploadResult {
    let path_str = path.display().to_string();
    let file_name = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string();
    let mut result = CoreUploadResult {
        path: path_str.clone(),
        ..Default::default()
    };
    let thread = |status: &str, message: String| CoreUploadEvent {
        event_type: "thread".into(),
        worker_id: worker,
        status: status.into(),
        file_path: path_str.clone(),
        file_name: file_name.clone(),
        message,
        ..Default::default()
    };

    let timestamp = async {
        let mtime = tokio::fs::metadata(path)
            .await
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
            .unwrap_or_default();
        if options.set_date_from_filename {
            timestamp_from_filename(path).unwrap_or(mtime)
        } else {
            mtime
        }
    }
    .await;

    state.emit_sync(thread("hashing", "Hashing...".into()));
    let sha1 = match sha1_file(path, cancel).await {
        Ok(hash) => hash,
        Err(err) => {
            result.is_error = true;
            result.error_message = err.to_string();
            return result;
        }
    };
    let sha1_b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &sha1);
    if cancel.is_cancelled() {
        return result;
    }

    if !options.force_upload {
        state.emit_sync(thread("checking", "Checking if file exists in library...".into()));
        match api.find_remote_media_by_hash(&sha1).await {
            Ok(key) if !key.is_empty() => {
                state.emit_sync(thread("completed", "Already in library".into()));
                result.media_key = key;
                result.skipped = true;
                result.skip_code = "remote-duplicate".into();
                result.skip_reason = "Skipped because this file already exists remotely".into();
                if options.delete_from_host {
                    if let Err(err) = tokio::fs::remove_file(path).await {
                        result.is_error = true;
                        result.error_message = format!("file exists in library but failed to delete local copy: {err}");
                    }
                }
                return result;
            }
            Ok(_) => {}
            Err(err) => {
                state.emit_sync(thread(
                    "checking",
                    format!("Hash check warning: {err}, proceeding with upload"),
                ));
            }
        }
    }

    let size = match tokio::fs::metadata(path).await {
        Ok(meta) => meta.len(),
        Err(err) => {
            result.is_error = true;
            result.error_message = err.to_string();
            return result;
        }
    };
    state.emit_sync(CoreUploadEvent {
        event_type: "thread".into(),
        worker_id: worker,
        status: "uploading".into(),
        file_path: path_str.clone(),
        file_name: file_name.clone(),
        message: "Uploading...".into(),
        bytes_total: size as i64,
        ..Default::default()
    });

    let upload_token = match api.get_upload_token(&sha1_b64, size).await {
        Ok(token) => token,
        Err(err) => {
            result.is_error = true;
            result.error_message = format!("error uploading file: {err}");
            return result;
        }
    };
    let state_for_progress = state.clone();
    let path_for_progress = path_str.clone();
    let name_for_progress = file_name.clone();
    let finalize = {
        api.upload_file(path, &upload_token, move |sent, total, attempt| {
            state_for_progress.emit_sync(CoreUploadEvent {
                event_type: "thread".into(),
                worker_id: worker,
                status: "uploading".into(),
                file_path: path_for_progress.clone(),
                file_name: name_for_progress.clone(),
                message: if attempt > 1 {
                    format!("Retrying... (attempt {attempt})")
                } else {
                    "Uploading...".into()
                },
                bytes_uploaded: sent,
                bytes_total: total,
                attempt,
                ..Default::default()
            });
        })
        .await
    };
    let finalize = match finalize {
        Ok(token) => token,
        Err(err) => {
            result.is_error = true;
            result.error_message = format!("error uploading file: {err}");
            return result;
        }
    };
    state.emit_sync(thread("finalizing", "Committing upload...".into()));
    match api
        .commit_upload(&finalize, &file_name, &sha1, timestamp)
        .await
    {
        Ok(key) => {
            result.media_key = key;
            if options.delete_from_host {
                if let Err(err) = tokio::fs::remove_file(path).await {
                    result.is_error = true;
                    result.error_message =
                        format!("uploaded successfully but failed to delete file: {err}");
                }
            }
        }
        Err(err) => {
            result.is_error = true;
            result.error_message = format!("error committing file: {err}");
        }
    }
    result
}

const SUPPORTED_EXTENSIONS: &[&str] = &[
    "avif", "bmp", "gif", "heic", "heif", "ico", "jpg", "jpeg", "png", "tif", "tiff", "webp",
    "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "pef", "sr2", "dng", "3gp", "3g2", "asf",
    "avi", "divx", "m2t", "m2ts", "m4v", "mkv", "mmv", "mod", "mov", "mp4", "mpg", "mpeg", "mts",
    "tod", "wmv", "ts", "webm",
];

pub fn discover_files(paths: &[String], options: &UploadOptions) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for raw in paths {
        let path = Path::new(raw);
        let meta = std::fs::metadata(path)
            .with_context(|| format!("error accessing path {raw}"))?;
        if meta.is_dir() {
            scan_dir(path, options, &mut files)?;
        } else {
            files.push(path.to_path_buf());
        }
    }
    let mut unique = Vec::with_capacity(files.len());
    for file in files {
        if !options.disable_unsupported_files_filter && !is_supported(&file) {
            continue;
        }
        let canonical = std::fs::canonicalize(&file).unwrap_or_else(|_| file.clone());
        if seen.insert(canonical) {
            unique.push(file);
        }
    }
    Ok(unique)
}

fn scan_dir(dir: &Path, options: &UploadOptions, out: &mut Vec<PathBuf>) -> Result<()> {
    let entries = std::fs::read_dir(dir).with_context(|| format!("error scanning {}", dir.display()))?;
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            if !options.exclude_pattern.is_empty()
                && path.file_name().and_then(|s| s.to_str()) == Some(options.exclude_pattern.as_str())
            {
                continue;
            }
            if options.recursive {
                scan_dir(&path, options, out)?;
            }
        } else {
            out.push(path);
        }
    }
    Ok(())
}

fn is_supported(path: &Path) -> bool {
    path.extension()
        .and_then(|s| s.to_str())
        .is_some_and(|ext| SUPPORTED_EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str()))
}

async fn sha1_file(path: &Path, cancel: &tokio_util::sync::CancellationToken) -> Result<Vec<u8>> {
    use tokio::io::AsyncReadExt;
    let mut file = tokio::fs::File::open(path)
        .await
        .with_context(|| format!("error calculating hash for {}", path.display()))?;
    let mut hasher = sha1::Sha1::new();
    let mut buffer = vec![0u8; 1024 * 1024];
    loop {
        if cancel.is_cancelled() {
            anyhow::bail!("cancelled");
        }
        let read = file.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher.finalize().to_vec())
}

pub fn timestamp_from_filename(path: &Path) -> Option<i64> {
    use regex::Regex;
    let base = path.file_name()?.to_str()?;
    let patterns: [( &str, bool, bool); 4] = [
        (r"(\d{4})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})\d*", true, false),
        (
            r"(\d{4})-(\d{1,2})-(\d{1,2})(?:[ _-](\d{2})(\d{2})(\d{2})\d*)?",
            false,
            false,
        ),
        (
            r"(?:^|[^0-9])(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:[^0-9]|$)",
            true,
            false,
        ),
        (r"(?:^|[^0-9])(1\d{12})(?:[^0-9]|$)", true, true),
    ];
    for (pattern, has_time, is_ms) in patterns {
        if let Some(caps) = Regex::new(pattern).ok()?.captures(base) {
            if is_ms {
                let ms: i64 = caps[1].parse().ok()?;
                let dt = chrono::DateTime::from_timestamp_millis(ms)?;
                let year = dt.year();
                if (1990..=Local::now().year() + 1).contains(&year) {
                    return Some(ms / 1000);
                }
                continue;
            }
            let pad = |s: &str| if s.len() < 2 { format!("0{s}") } else { s.to_string() };
            let (hour, min, sec) = if has_time || caps.len() >= 7 {
                (caps.get(4).map(|m| m.as_str()).unwrap_or("12"),
                 caps.get(5).map(|m| m.as_str()).unwrap_or("00"),
                 caps.get(6).map(|m| m.as_str()).unwrap_or("00"))
            } else {
                ("12", "00", "00")
            };
            let stamp = format!(
                "{}{}{} {}{}{}",
                &caps[1], pad(&caps[2]), pad(&caps[3]), pad(hour), min, sec
            );
            if let Ok(naive) = NaiveDateTime::parse_from_str(&stamp, "%Y%m%d %H%M%S") {
                if let Some(local) = Local.from_local_datetime(&naive).single() {
                    let year = local.year();
                    if (1990..=Local::now().year() + 1).contains(&year) {
                        return Some(local.timestamp());
                    }
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supported_extensions() {
        assert!(is_supported(Path::new("photo.JPG")));
        assert!(is_supported(Path::new("clip.mp4")));
        assert!(!is_supported(Path::new("notes.txt")));
    }

    #[test]
    fn filename_dates() {
        let stamp = timestamp_from_filename(Path::new("/x/PXL_20231123_182518628.jpg"));
        assert!(stamp.is_some(), "must parse PXL filename");
        let stamp = timestamp_from_filename(Path::new("/x/FaceApp_1658848332262.jpg"));
        assert_eq!(stamp, Some(1_658_848_332));
    }

    #[test]
    fn discovery_filters_and_dedups() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.jpg"), b"a").unwrap();
        std::fs::write(dir.path().join("b.txt"), b"b").unwrap();
        let options = UploadOptions {
            credential: "x=1".into(),
            threads: 1,
            ..UploadOptions::from_preferences(&Preferences::default(), "x=1".into())
        };
        let files = discover_files(
            &[dir.path().display().to_string()],
            &options,
        )
        .unwrap();
        assert_eq!(files.len(), 1);
        assert!(files[0].ends_with("a.jpg"));
    }
}
