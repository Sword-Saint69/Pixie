//! Google account sign-in and master-token exchange.
//! Constants and field names are taken verbatim from the reference client's
//! `core/googleauth.go` at commit 2a5c1b9.

use crate::core::config::{parse_query, serialize_query};
use anyhow::{bail, Context, Result};
use std::collections::HashMap;
use std::time::Duration;

pub const EMBEDDED_SETUP_AUTH_ENDPOINT: &str = "https://android.clients.google.com/auth";
pub const GOOGLE_PHOTOS_PACKAGE: &str = "com.google.android.apps.photos";
pub const GOOGLE_PLAY_SERVICES_SIG: &str = "38918a453d07199354f8b19af05ec6562ced5788";
pub const GOOGLE_PHOTOS_SIG: &str = "24bb24c05e47e0aefa68a58a766179d9b613a600";
pub const GOOGLE_PHOTOS_SERVICE: &str = "oauth2:openid https://www.googleapis.com/auth/mobileapps.native https://www.googleapis.com/auth/photos.native";

pub struct GoogleExchange {
    pub email: String,
    pub master_token: String,
}

pub fn normalize_oauth_token(value: &str) -> Result<String> {
    let value = value.trim();
    let value = value.strip_prefix("oauth_token=").unwrap_or(value);
    if value.len() < 16 || value.len() > 8192 || value.contains(['\r', '\n']) {
        bail!("enter the oauth_token cookie value from Google Embedded Setup");
    }
    Ok(value.to_string())
}

pub fn generate_android_id() -> String {
    let mut raw = [0u8; 8];
    rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut raw);
    hex_encode(&raw)
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0xf) as usize] as char);
    }
    out
}

pub fn build_google_photos_credential(email: &str, master_token: &str, android_id: &str) -> String {
    let mut p: HashMap<String, String> = HashMap::new();
    p.insert("androidId".into(), android_id.into());
    p.insert("app".into(), GOOGLE_PHOTOS_PACKAGE.into());
    p.insert("callerPkg".into(), GOOGLE_PHOTOS_PACKAGE.into());
    p.insert("callerSig".into(), GOOGLE_PHOTOS_SIG.into());
    p.insert("client_sig".into(), GOOGLE_PHOTOS_SIG.into());
    p.insert("device_country".into(), "us".into());
    p.insert("Email".into(), email.into());
    p.insert("google_play_services_version".into(), "240913000".into());
    p.insert("lang".into(), "en_US".into());
    p.insert("oauth2_foreground".into(), "1".into());
    p.insert("operatorCountry".into(), "us".into());
    p.insert("sdk_version".into(), "33".into());
    p.insert("service".into(), GOOGLE_PHOTOS_SERVICE.into());
    p.insert("source".into(), "android".into());
    p.insert("Token".into(), master_token.into());
    serialize_query(&p)
}

/// Exchanges an Embedded Setup `oauth_token` for the Photos master token.
/// Redirects are rejected so a token-bearing request is never forwarded.
pub async fn exchange_embedded_setup_token(
    oauth_token: &str,
    android_id: &str,
    proxy: &str,
) -> Result<GoogleExchange> {
    let oauth_token = normalize_oauth_token(oauth_token)?;
    let mut form: HashMap<&str, String> = HashMap::new();
    form.insert("accountType", "HOSTED_OR_GOOGLE".to_string());
    form.insert("Email", "oauth-token@example.com".to_string());
    form.insert("has_permission", "1".to_string());
    form.insert("add_account", "1".to_string());
    form.insert("ACCESS_TOKEN", "1".to_string());
    form.insert("Token", oauth_token.clone());
    form.insert("service", "ac2dm".to_string());
    form.insert("source", "android".to_string());
    form.insert("androidId", android_id.to_string());
    form.insert("device_country", "us".to_string());
    form.insert("operatorCountry", "us".to_string());
    form.insert("lang", "en".to_string());
    form.insert("sdk_version", "17".to_string());
    form.insert("google_play_services_version", "240913000".to_string());
    form.insert("client_sig", GOOGLE_PLAY_SERVICES_SIG.to_string());
    form.insert("callerSig", GOOGLE_PLAY_SERVICES_SIG.to_string());
    form.insert("droidguard_results", "dummy123".to_string());
    let body = serialize_query(&form);

    let mut builder = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("GoogleAuth/1.4");
    if !proxy.trim().is_empty() {
        builder = builder
            .proxy(reqwest::Proxy::all(proxy.trim()).context("invalid proxy URL")?)
            .danger_accept_invalid_certs(true);
    }
    let client = builder.build()?;

    let response = client
        .post(EMBEDDED_SETUP_AUTH_ENDPOINT)
        .header("Accept-Encoding", "identity")
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(body)
        .send()
        .await
        .context("contact Google authentication")?;
    let status = response.status();
    let bytes = response.bytes().await.unwrap_or_default();
    let body = String::from_utf8_lossy(&bytes);
    if !status.is_success() {
        bail!("Google authentication returned HTTP {}", status.as_u16());
    }
    let values = parse_key_value_lines(&body);
    if let Some(code) = values.get("Error") {
        bail!("{}", auth_error_message(code));
    }
    let master_token = values
        .get("Token")
        .filter(|s| !s.is_empty())
        .context("Google authentication response did not contain a master token")?
        .clone();
    let email = values
        .get("Email")
        .map(|s| s.trim().to_string())
        .filter(|s| s.contains('@') && !s.starts_with('@') && !s.ends_with('@'))
        .context("Google authentication response did not contain a valid account email")?;

    Ok(GoogleExchange {
        email,
        master_token,
    })
}

pub fn parse_key_value_lines(body: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for line in body.lines() {
        let line = line.trim();
        if let Some((key, value)) = line.split_once('=') {
            out.insert(key.to_string(), value.to_string());
        }
    }
    out
}

fn auth_error_message(code: &str) -> String {
    match code {
        "BadAuthentication" => {
            "Google rejected the oauth_token; obtain a fresh cookie and try again".into()
        }
        "NeedsBrowser" => "Google requires a fresh Embedded Setup sign-in".into(),
        "MissingDroidguard" => "Google rejected the device verification data".into(),
        other => format!("Google authentication failed with {other}"),
    }
}

/// A raw credential string is a query string with Email and Token present.
pub fn looks_like_auth_string(value: &str) -> bool {
    let value = value.trim();
    if !value.contains('=') {
        return false;
    }
    let params = parse_query(value);
    params.contains_key("Email") && params.contains_key("Token")
}

pub fn validate_credential_shape(credential: &str) -> Result<String> {
    let required = [
        "androidId",
        "app",
        "client_sig",
        "Email",
        "Token",
        "lang",
        "service",
    ];
    let params = parse_query(credential);
    let missing: Vec<&str> = required
        .iter()
        .copied()
        .filter(|key| params.get(*key).is_none_or(|v| v.is_empty()))
        .collect();
    if !missing.is_empty() {
        bail!(
            "auth string missing required fields: {}",
            missing.join(", ")
        );
    }
    Ok(params["Email"].clone())
}

pub fn credential_needs_token_binding(credential: &str) -> bool {
    let params = parse_query(credential);
    params.contains_key("assertion_jwt") || params.contains_key("check_tb_upgrade_eligible")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oauth_token_normalized() {
        assert_eq!(
            normalize_oauth_token(" oauth_token=abcdefghijklmnop ").unwrap(),
            "abcdefghijklmnop"
        );
        assert!(normalize_oauth_token("short").is_err());
    }

    #[test]
    fn build_credential_has_required_fields() {
        let cred = build_google_photos_credential("u@example.com", "TOKEN", "aabbccdd");
        let params = parse_query(&cred);
        assert_eq!(params["Token"], "TOKEN");
        assert_eq!(params["callerSig"], GOOGLE_PHOTOS_SIG);
        assert_eq!(validate_credential_shape(&cred).unwrap(), "u@example.com");
    }

    #[test]
    fn parses_key_value_auth_reply() {
        let values = parse_key_value_lines("SID=x\nAuth=y\nExpiry=123\n");
        assert_eq!(values["Auth"], "y");
        assert_eq!(values["Expiry"], "123");
    }
}
