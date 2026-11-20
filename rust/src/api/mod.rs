//! Public API exposed to Dart by flutter_rust_bridge.
//! Keep types flat and primitive-only; the bridge generates Dart classes for
//! every struct declared here.

pub mod app_types;

pub use app_types::*;

use crate::core::config::ConfigStore;
use crate::core::upload::UploadState;
use std::sync::OnceLock;

pub(crate) fn config_store() -> std::sync::Arc<ConfigStore> {
    static STORE: OnceLock<std::sync::Arc<ConfigStore>> = OnceLock::new();
    STORE
        .get_or_init(|| std::sync::Arc::new(ConfigStore::load(None).expect("load gotohp.config")))
        .clone()
}

pub(crate) fn upload_state() -> std::sync::Arc<UploadState> {
    static STATE: OnceLock<std::sync::Arc<UploadState>> = OnceLock::new();
    STATE
        .get_or_init(|| std::sync::Arc::new(UploadState::default()))
        .clone()
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    let store = config_store();
    let _ = upload_state();
    if let Err(err) = crate::core::embedded::ensure_embedded_account(&store) {
        eprintln!("embedded credential not installed: {err:#}");
    }
}

pub fn config_path() -> String {
    config_store().path().display().to_string()
}

pub fn get_settings() -> AppSettings {
    AppSettings::from(config_store().preferences())
}

pub fn save_settings(settings: AppSettings) -> anyhow::Result<()> {
    config_store().update_preferences(settings.into_core())
}

pub fn list_accounts() -> Vec<AccountInfo> {
    config_store()
        .accounts()
        .into_iter()
        .map(|a| AccountInfo {
            email: a.email,
            needs_token_binding: a.needs_token_binding,
        })
        .collect()
}

pub fn selected_account() -> String {
    config_store().selected()
}

pub fn select_account(email: String) -> anyhow::Result<()> {
    config_store().select_account(&email)
}

pub fn add_account_raw(credential: String) -> anyhow::Result<String> {
    crate::core::auth::validate_credential_shape(&credential)?;
    config_store().upsert_credential(credential.trim())
}

pub fn add_account_oauth(oauth_token: String, proxy: String) -> anyhow::Result<String> {
    let android_id = crate::core::auth::generate_android_id();
    let exchange = crate::core::runtime().block_on(
        crate::core::auth::exchange_embedded_setup_token(&oauth_token, &android_id, &proxy),
    )?;
    let credential = crate::core::auth::build_google_photos_credential(
        &exchange.email,
        &exchange.master_token,
        &android_id,
    );
    let api = crate::core::api::Api::new(&credential, &proxy, false, false)?;
    crate::core::runtime().block_on(api.validate())?;
    config_store().upsert_credential(&credential)
}

pub fn remove_account(email: String) -> anyhow::Result<()> {
    config_store().remove_account(&email)
}

pub fn validate_account(email: String) -> anyhow::Result<()> {
    let credential = config_store().credential_for(&email)?;
    let prefs = config_store().preferences();
    let api = crate::core::api::Api::new(&credential, &prefs.proxy, prefs.saver, prefs.use_quota)?;
    crate::core::runtime().block_on(api.validate())
}

pub fn preview_files(paths: Vec<String>, settings: AppSettings) -> anyhow::Result<Vec<String>> {
    let credential = config_store().credential_for("")?;
    let options =
        crate::core::upload::UploadOptions::from_preferences(&settings.into_core(), credential);
    Ok(crate::core::upload::discover_files(&paths, &options)?
        .into_iter()
        .map(|p| p.display().to_string())
        .collect())
}

pub fn start_upload(
    paths: Vec<String>,
    settings: AppSettings,
    album_name: String,
    album_auto: bool,
    account: String,
) -> anyhow::Result<()> {
    let credential = config_store().credential_for(&account)?;
    let mut options =
        crate::core::upload::UploadOptions::from_preferences(&settings.into_core(), credential);
    options.album_name = album_name;
    options.album_auto = album_auto;
    crate::core::upload::start_upload(upload_state(), paths, options)
}

pub fn cancel_upload() {
    upload_state().cancel();
}

pub fn is_upload_running() -> bool {
    upload_state().is_running()
}

pub fn drain_events() -> Vec<UploadEvent> {
    upload_state()
        .drain_events()
        .into_iter()
        .map(UploadEvent::from)
        .collect()
}

pub fn get_summary() -> UploadSummary {
    upload_state().summary().into()
}

pub fn core_info() -> CoreInfo {
    CoreInfo {
        crate_version: env!("CARGO_PKG_VERSION").to_string(),
        bridge_version: "2.13.0".to_string(),
        target: format!("{}-{}", std::env::consts::OS, std::env::consts::ARCH),
        features: "tokio, reqwest/rustls, prost, cargokit".to_string(),
    }
}

pub fn preview_files_detailed(
    paths: Vec<String>,
    settings: AppSettings,
) -> anyhow::Result<Vec<FilePreview>> {
    let credential = config_store().credential_for("")?;
    let options =
        crate::core::upload::UploadOptions::from_preferences(&settings.into_core(), credential);
    Ok(crate::core::upload::discover_files(&paths, &options)?
        .into_iter()
        .map(|path| FilePreview {
            size_bytes: std::fs::metadata(&path)
                .map(|m| m.len() as i64)
                .unwrap_or(0),
            path: path.display().to_string(),
        })
        .collect())
}

pub fn get_progress() -> UploadProgress {
    upload_state().progress().into()
}

pub fn pause_upload() {
    upload_state().pause();
}

pub fn resume_upload() {
    upload_state().resume();
}

pub fn is_upload_paused() -> bool {
    upload_state().is_paused()
}
