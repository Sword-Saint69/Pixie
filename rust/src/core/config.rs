//! On-disk configuration, kept wire-compatible with xob0t/gotohp's
//! `gotohp.config` (YAML, keys from the upstream `koanf` tags).

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::RwLock;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct AccountConfig {
    pub credentials: Vec<String>,
    pub selected: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
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

impl Default for Preferences {
    fn default() -> Self {
        Self {
            proxy: String::new(),
            use_quota: false,
            saver: false,
            recursive: false,
            force_upload: false,
            pair_live_photos: false,
            skip_incomplete_live_photos: true,
            update_existing_photos_to_live: false,
            upload_threads: 3,
            delete_from_host: false,
            disable_unsupported_files_filter: false,
            set_date_from_filename: false,
            exclude_pattern: String::new(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub account: AccountConfig,
    pub preferences: Preferences,
}

pub struct ConfigStore {
    path: PathBuf,
    config: RwLock<Config>,
}

impl ConfigStore {
    pub fn load(path: Option<PathBuf>) -> Result<Self> {
        let path = path.unwrap_or_else(determine_config_path);
        let config = load_file(&path).unwrap_or_else(|err| {
            eprintln!(
                "warning: ignoring unreadable config {}: {err:#}",
                path.display()
            );
            Config::default()
        });
        Ok(Self {
            path,
            config: RwLock::new(config),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn snapshot(&self) -> Config {
        self.config.read().expect("config lock poisoned").clone()
    }

    pub fn preferences(&self) -> Preferences {
        self.snapshot().preferences
    }

    pub fn update_preferences(&self, prefs: Preferences) -> Result<()> {
        {
            let mut guard = self.config.write().expect("config lock poisoned");
            guard.preferences = prefs;
            self.write_locked(&guard)?;
        }
        Ok(())
    }

    pub fn accounts(&self) -> Vec<CoreAccountInfo> {
        self.snapshot()
            .account
            .credentials
            .iter()
            .filter_map(|cred| {
                let params = parse_query(cred);
                let email = params.get("Email").cloned().unwrap_or_default();
                if email.is_empty() {
                    return None;
                }
                Some(CoreAccountInfo {
                    email,
                    needs_token_binding: params.contains_key("assertion_jwt")
                        || params.contains_key("check_tb_upgrade_eligible"),
                })
            })
            .collect()
    }

    pub fn selected(&self) -> String {
        self.snapshot().account.selected
    }

    pub fn select_account(&self, email: &str) -> Result<()> {
        let email = email.trim();
        if !self
            .accounts()
            .iter()
            .any(|a| a.email.eq_ignore_ascii_case(email))
        {
            anyhow::bail!("no credentials found for account {email}");
        }
        let mut guard = self.config.write().expect("config lock poisoned");
        guard.account.selected = email.to_string();
        self.write_locked(&guard)
    }

    /// Adds or replaces the credential for an email. Mirrors the upstream
    /// `upsertCredential`: email is case-insensitive and becomes selected.
    pub fn upsert_credential(&self, credential: &str) -> Result<String> {
        let params = parse_query(credential);
        let email = params
            .get("Email")
            .cloned()
            .filter(|s| !s.is_empty())
            .context("credential has no Email field")?;
        let mut guard = self.config.write().expect("config lock poisoned");
        let mut replaced = false;
        for existing in &mut guard.account.credentials {
            if parse_query(existing)
                .get("Email")
                .is_some_and(|e| e.eq_ignore_ascii_case(&email))
            {
                *existing = credential.to_string();
                replaced = true;
                break;
            }
        }
        if !replaced {
            guard.account.credentials.push(credential.to_string());
        }
        guard.account.selected = email.clone();
        self.write_locked(&guard)?;
        Ok(email)
    }

    pub fn remove_account(&self, email: &str) -> Result<()> {
        if email.trim().is_empty() {
            anyhow::bail!("email cannot be empty");
        }
        let mut guard = self.config.write().expect("config lock poisoned");
        let before = guard.account.credentials.len();
        guard
            .account
            .credentials
            .retain(|c| !parse_query(c).get("Email").is_some_and(|e| e == email));
        if guard.account.credentials.len() == before {
            anyhow::bail!("no credentials found for email {email}");
        }
        if guard.account.selected.eq_ignore_ascii_case(email) {
            guard.account.selected.clear();
        }
        self.write_locked(&guard)
    }

    pub fn credential_for(&self, email: &str) -> Result<String> {
        let config = self.snapshot();
        let wanted = if email.is_empty() {
            config.account.selected.as_str()
        } else {
            email
        };
        if wanted.is_empty() {
            anyhow::bail!("no account is selected");
        }
        config
            .account
            .credentials
            .into_iter()
            .find(|c| {
                parse_query(c)
                    .get("Email")
                    .is_some_and(|e| e.eq_ignore_ascii_case(wanted))
            })
            .with_context(|| format!("no credentials found for account {wanted}"))
    }

    pub fn set_token_binding_alias(&self, email: &str, alias: &str) -> Result<()> {
        let mut guard = self.config.write().expect("config lock poisoned");
        for cred in &mut guard.account.credentials {
            if parse_query(cred).get("Email").is_some_and(|e| e == email) {
                let mut params = parse_query(cred);
                params.insert("token_binding_alias".into(), alias.into());
                *cred = serialize_query(&params);
                return self.write_locked(&guard);
            }
        }
        anyhow::bail!("no credentials found for email {email}")
    }

    fn write_locked(&self, config: &Config) -> Result<()> {
        let bytes = serde_yaml::to_string(config)?;
        let parent = self.path.parent().unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(parent)
            .with_context(|| format!("create config directory {}", parent.display()))?;
        let tmp = parent.join(format!(
            ".gotohp-config-{}-{}",
            std::process::id(),
            rand::random::<u64>()
        ));
        {
            let mut file = fs::File::create(&tmp)?;
            file.write_all(bytes.as_bytes())?;
            file.sync_all()?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
            }
        }
        match fs::rename(&tmp, &self.path) {
            Ok(()) => Ok(()),
            Err(err) => {
                let _ = fs::remove_file(&tmp);
                Err(err).with_context(|| format!("replace config file {}", self.path.display()))
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct CoreAccountInfo {
    pub email: String,
    pub needs_token_binding: bool,
}

fn load_file(path: &Path) -> Result<Config> {
    let contents = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    if contents.trim().is_empty() {
        return Ok(Config::default());
    }
    serde_yaml::from_str(&contents).with_context(|| format!("parse {}", path.display()))
}

/// Portable config next to the executable or in the working directory wins,
/// exactly as in the original client.
pub fn determine_config_path() -> PathBuf {
    // Inside an Android app the CWD is "/" and the executable lives in the
    // read-only APK/lib directory; XDG/HOME points at an unwritable place.
    // Use the app's own private data directory instead.
    #[cfg(target_os = "android")]
    {
        return PathBuf::from("/data/data/com.example.gotohp_rs/files/gotohp.config");
    }

    #[cfg(not(target_os = "android"))]
    {
        let local = PathBuf::from("gotohp.config");
        if local.exists() {
            return local;
        }
        if let Ok(exe) = std::env::current_exe() {
            let candidate = exe.parent().unwrap_or(Path::new(".")).join("gotohp.config");
            if candidate.exists() {
                return candidate;
            }
        }
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("gotohp")
            .join("gotohp.config")
    }
}

pub fn parse_query(input: &str) -> HashMap<String, String> {
    url::form_urlencoded::parse(input.as_bytes())
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect()
}

pub fn serialize_query<S: AsRef<str>>(params: &HashMap<S, String>) -> String {
    let mut serializer = url::form_urlencoded::Serializer::new(String::new());
    let mut keys: Vec<_> = params.iter().collect();
    keys.sort_by(|a, b| a.0.as_ref().cmp(b.0.as_ref()));
    for (key, value) in keys {
        serializer.append_pair(key.as_ref(), value);
    }
    serializer.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_roundtrip() {
        let mut params = HashMap::new();
        params.insert("Email".to_owned(), "user@example.com".to_owned());
        params.insert("Token".to_owned(), "a+b/c=".to_owned());
        let encoded = serialize_query(&params);
        assert_eq!(parse_query(&encoded), params);
    }

    #[test]
    fn malformed_config_falls_back_to_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("gotohp.config");
        fs::write(&path, "account: [not valid").unwrap();
        let store = ConfigStore::load(Some(path)).unwrap();
        assert_eq!(store.preferences().upload_threads, 3);
        assert!(store.accounts().is_empty());
    }

    #[test]
    fn config_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("gotohp.config");
        let store = ConfigStore::load(Some(path.clone())).unwrap();
        let prefs = Preferences {
            upload_threads: 7,
            exclude_pattern: "thumbs".into(),
            ..Preferences::default()
        };
        store.update_preferences(prefs.clone()).unwrap();
        assert_eq!(
            ConfigStore::load(Some(path))
                .unwrap()
                .preferences()
                .upload_threads,
            7
        );
        let text = fs::read_to_string(store.path()).unwrap();
        assert!(text.contains("upload_threads: 7"), "{text}");
        assert!(text.contains("skip_incomplete_live_photos: true"), "{text}");
    }
}
