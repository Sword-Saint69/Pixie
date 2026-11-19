//! Photos private-API client. Endpoints, headers, protobuf field numbers and
//! device fingerprint are ported from xob0t/gotohp `core/api.go` (2a5c1b9).

use crate::core::config::parse_query;
use crate::core::proto::pb::commit_upload::field1_type::{
    Field1Type as CommitField1Inner, Field4Type as CommitField4,
};
use crate::core::proto::pb::commit_upload::{Field1Type as CommitField1, Field2Type as CommitDevice};
use crate::core::proto::pb::hash_check::field1_type::{
    Field1Type as HashInner, Field2Type as HashProbe,
};
use crate::core::proto::pb::hash_check::Field1Type as HashOuter;
use crate::core::proto::pb::{
    CommitToken, CommitUpload, CreateMediaItemsResponse, GetUploadToken, HashCheck, RemoteMatches,
};
use anyhow::{bail, Context, Result};
use futures::StreamExt;
use prost::Message;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;

const CREATE_MEDIA_ITEMS_ENDPOINT: &str =
    "https://photosdata-pa.googleapis.com/6439526531001121323/16538846908252377752";
const HASH_CHECK_ENDPOINT: &str =
    "https://photosdata-pa.googleapis.com/6439526531001121323/5084965799730810217";
const CREATE_ALBUM_ENDPOINT: &str =
    "https://photosdata-pa.googleapis.com/6439526531001121323/8386163679468898444";
const ADD_MEDIA_TO_ALBUM_ENDPOINT: &str =
    "https://photosdata-pa.googleapis.com/6439526531001121323/484917746253879292";
const UPLOAD_ENDPOINT: &str = "https://photos.googleapis.com/data/upload/uploadmedia/interactive";
const AUTH_ENDPOINT: &str = "https://android.googleapis.com/auth";

const ANDROID_API_VERSION: i64 = 28;
const MAKE: &str = "Google";
const MODEL: &str = "Pixel XL";
const CLIENT_VERSION_CODE: i64 = 49_029_607;

#[derive(Default)]
struct AuthCache {
    expiry: i64,
    auth: String,
}

pub struct Api {
    language: String,
    auth_data: String,
    user_agent: String,
    client: reqwest::Client,
    auth_cache: Mutex<AuthCache>,
    saver: bool,
    use_quota: bool,
}

impl Api {
    pub fn new(credential: &str, proxy: &str, saver: bool, use_quota: bool) -> Result<Self> {
        let params = parse_query(credential);
        let language = params.get("lang").cloned().unwrap_or_default();
        let android_id = params
            .get("androidId")
            .cloned()
            .context("credential is missing androidId")?;

        let mut builder = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .pool_max_idle_per_host(10)
            .gzip(true);
        if !proxy.trim().is_empty() {
            builder = builder
                .proxy(reqwest::Proxy::all(proxy.trim()).context("invalid proxy URL")?)
                .danger_accept_invalid_certs(true);
        }
        // Match GODEBUG=http2client=0 behaviour of the reference client: use
        // HTTP/1.1 so chunked upload framing stays identical.
        builder = builder.http1_only();
        let client = builder
            .default_headers(reqwest::header::HeaderMap::new())
            .build()?;

        let user_agent = format!(
            "com.google.android.apps.photos/{CLIENT_VERSION_CODE} (Linux; U; Android 9; {language}; {MODEL}; Build/PQ2A.190205.001; Cronet/127.0.6510.5) (gzip)"
        );
        let _ = android_id; // used as the `device` header on the auth request

        Ok(Self {
            language,
            auth_data: credential.trim().to_string(),
            user_agent,
            client,
            auth_cache: Mutex::new(AuthCache::default()),
            saver,
            use_quota,
        })
    }

    pub async fn bearer_token(&self) -> Result<String> {
        let now = now_unix();
        let cached = {
            let cache = self.auth_cache.lock().await;
            (cache.expiry > now).then(|| cache.auth.clone())
        };
        if let Some(token) = cached {
            if !token.is_empty() {
                return Ok(token);
            }
        }
        let refreshed = self.get_auth_token().await?;
        let expiry = refreshed
            .get("Expiry")
            .and_then(|s| s.parse::<i64>().ok())
            .context("auth response missing Expiry")?;
        let auth = refreshed
            .get("Auth")
            .filter(|s| !s.is_empty())
            .context("auth response missing Auth token")?
            .clone();
        *self.auth_cache.lock().await = AuthCache { expiry, auth: auth.clone() };
        Ok(auth)
    }

    async fn get_auth_token(&self) -> Result<HashMap<String, String>> {
        let mut form = parse_query(&self.auth_data);
        form.insert("app".into(), "com.google.android.apps.photos".into());
        form.insert("callerPkg".into(), "com.google.android.apps.photos".into());
        form.remove("it_caveat_types");
        form.remove("assertion_jwt");
        if let Some(alias) = form.remove("token_binding_alias") {
            bail!(
                "credential requires token binding (alias {alias}); this port cannot sign the assertion without the Android keystore key"
            );
        }
        let device = form
            .get("androidId")
            .cloned()
            .context("credential is missing androidId")?;
        let body = crate::core::config::serialize_query(&form);

        let response = self
            .client
            .post(AUTH_ENDPOINT)
            .header("Accept-Encoding", "gzip")
            .header("app", "com.google.android.apps.photos")
            .header("Connection", "Keep-Alive")
            .header("Content-Type", "application/x-www-form-urlencoded")
            .header("device", device)
            .header("User-Agent", "GoogleAuth/1.4 (Pixel XL PQ2A.190205.001); gzip")
            .body(body)
            .send()
            .await
            .context("auth request failed")?;
        let status = response.status();
        let bytes = response.bytes().await?;
        if !status.is_success() {
            bail!(
                "auth request failed with status {}: {}",
                status.as_u16(),
                String::from_utf8_lossy(&bytes)
            );
        }
        let text = String::from_utf8_lossy(&bytes);
        let values = crate::core::auth::parse_key_value_lines(&text);
        if let Some(encrypted) = values
            .get("AuthEncrypted")
            .or_else(|| values.get("Encrypted"))
        {
            bail!("auth response is token-encrypted ({}-byte payload); token binding is required", encrypted.len());
        }
        Ok(values)
    }

    /// Returns the upload session id from `X-GUploader-UploadID`.
    pub async fn get_upload_token(&self, sha1_b64: &str, file_size: u64) -> Result<String> {
        let message = GetUploadToken {
            f1: 2,
            f2: 2,
            f3: 1,
            f4: 3,
            file_size_bytes: file_size as i64,
        };
        let response = self
            .client
            .post(UPLOAD_ENDPOINT)
            .headers(self.protobuf_headers().await?)
            .header("X-Goog-Hash", format!("sha1={sha1_b64}"))
            .header("X-Upload-Content-Length", file_size.to_string())
            .body(message.encode_to_vec())
            .send()
            .await
            .context("upload token request failed")?;
        let status = response.status();
        let token = response
            .headers()
            .get("X-GUploader-UploadID")
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        let bytes = response.bytes().await.unwrap_or_default();
        if !status.is_success() {
            bail!(
                "upload token request failed with status {}: {}",
                status.as_u16(),
                String::from_utf8_lossy(&bytes)
            );
        }
        token.context("response missing X-GUploader-UploadID header")
    }

    /// Returns the media key of an already-uploaded file, or an empty string.
    pub async fn find_remote_media_by_hash(&self, sha1: &[u8]) -> Result<String> {
        let message = HashCheck {
            field1: Some(HashOuter {
                field1: Some(HashInner {
                    sha1_hash: sha1.to_vec(),
                }),
                field2: Some(HashProbe {}),
            }),
        };
        let response = self
            .client
            .post(HASH_CHECK_ENDPOINT)
            .headers(self.protobuf_headers().await?)
            .body(message.encode_to_vec())
            .send()
            .await
            .context("hash check request failed")?;
        let status = response.status();
        let bytes = response.bytes().await?;
        if !status.is_success() {
            bail!(
                "hash check failed with status {}: {}",
                status.as_u16(),
                String::from_utf8_lossy(&bytes)
            );
        }
        let parsed = RemoteMatches::decode(bytes.as_ref()).context("invalid hash-check response")?;
        Ok(parsed
            .field1
            .and_then(|f| f.field2)
            .and_then(|f| f.field2)
            .map(|f| f.media_key)
            .unwrap_or_default())
    }

    /// Streaming PUT of a file, with per-attempt progress callbacks.
    pub async fn upload_file<F>(
        &self,
        path: &Path,
        upload_token: &str,
        on_progress: F,
    ) -> Result<Vec<u8>>
    where
        F: Fn(i64, i64, i32) + Send + Sync + 'static,
    {
        let url = format!("{UPLOAD_ENDPOINT}?upload_id={upload_token}");
        let callback: ProgressCallback = Arc::new(on_progress);
        let mut last_error = None;
        for attempt in 0usize..=3 {
            let attempt_no = (attempt + 1) as i32;
            callback(0, 0, attempt_no);
            match self.upload_once(&url, path, &callback, attempt_no).await {
                Ok(token) => return Ok(token),
                Err(err) => {
                    last_error = Some(err);
                    if attempt < 3 {
                        tokio::time::sleep(backoff(attempt)).await;
                    }
                }
            }
        }
        Err(last_error.unwrap_or_else(|| anyhow::anyhow!("upload failed")))
    }

    async fn upload_once(
        &self,
        url: &str,
        path: &Path,
        on_progress: &ProgressCallback,
        attempt_no: i32,
    ) -> Result<Vec<u8>> {
        let file = tokio::fs::File::open(path)
            .await
            .with_context(|| format!("open {}", path.display()))?;
        let total = file.metadata().await?.len() as i64;
        let reader = tokio_util::io::ReaderStream::new(file);
        let mut sent: i64 = 0;
        let callback = on_progress.clone();
        let reader = reader.map(move |chunk| {
            let chunk = match chunk {
                Ok(bytes) => bytes,
                Err(err) => {
                    // reqwest propagates the stream error to the caller.
                    return Err(std::io::Error::other(err));
                }
            };
            sent += chunk.len() as i64;
            callback(sent, total, attempt_no);
            Ok(chunk)
        });
        let body = reqwest::Body::wrap_stream(reader);
        let bearer = self.bearer_token().await?;
        let response = self
            .client
            .put(url)
            .header("Accept-Encoding", "gzip")
            .header("Accept-Language", &self.language)
            .header("User-Agent", &self.user_agent)
            .header("Authorization", format!("Bearer {bearer}"))
            .body(body)
            .send()
            .await
            .context("upload request failed")?;
        let status = response.status();
        let bytes = response.bytes().await?;
        if !status.is_success() {
            bail!(
                "upload failed with status {}: {}",
                status.as_u16(),
                String::from_utf8_lossy(&bytes)
            );
        }
        let token = CommitToken::decode(bytes.as_ref()).context("invalid upload finalize token")?;
        if token.field1 != 2 || token.field2.is_empty() {
            bail!("unsupported upload finalize token");
        }
        // The reference client embeds the raw envelope, not a re-encoded copy.
        Ok(bytes.to_vec())
    }

    /// Commits an uploaded file and returns its media key.
    pub async fn commit_upload(
        &self,
        finalize_token: &[u8],
        file_name: &str,
        sha1: &[u8],
        timestamp: i64,
    ) -> Result<String> {
        let token = CommitToken::decode(finalize_token).context("decode finalize token")?;
        let quality = if self.saver { 1 } else { 3 };
        let model = if self.use_quota {
            "Pixel 8"
        } else if self.saver {
            "Pixel 2"
        } else {
            MODEL
        };
        let message = CommitUpload {
            field1: Some(CommitField1 {
                field1: Some(CommitField1Inner {
                    field1: token.field1,
                    field2: token.field2,
                }),
                file_name: file_name.to_string(),
                sha1_hash: sha1.to_vec(),
                field4: Some(CommitField4 {
                    file_last_modified_timestamp: if timestamp == 0 {
                        now_unix()
                    } else {
                        timestamp
                    },
                    field2: 46_000_000,
                }),
                quality,
                field10: 1,
                field17: 0,
                field8: None,
            }),
            field2: Some(CommitDevice {
                model: model.to_string(),
                make: MAKE.to_string(),
                android_api_version: ANDROID_API_VERSION,
            }),
            field3: vec![1, 3],
        };
        let body = message.encode_to_vec();
        let mut last_error = None;
        for attempt in 0usize..=3 {
            match self.commit_once(&body).await {
                Ok(key) => return Ok(key),
                Err((err, retryable)) => {
                    last_error = Some(err);
                    if !retryable || attempt == 3 {
                        break;
                    }
                    tokio::time::sleep(backoff(attempt)).await;
                }
            }
        }
        Err(last_error.unwrap_or_else(|| anyhow::anyhow!("commit failed")))
    }

    async fn commit_once(&self, body: &[u8]) -> std::result::Result<String, (anyhow::Error, bool)> {
        let bearer = self
            .bearer_token()
            .await
            .map_err(|e| (e, true))?;
        let response = self
            .client
            .post(CREATE_MEDIA_ITEMS_ENDPOINT)
            .header("Accept-Encoding", "gzip")
            .header("Accept-Language", &self.language)
            .header("Content-Type", "application/x-protobuf")
            .header("User-Agent", &self.user_agent)
            .header("Authorization", format!("Bearer {bearer}"))
            .header("x-goog-ext-173412678-bin", "CgcIAhClARgC")
            .header("x-goog-ext-174067345-bin", "CgIIAg==")
            .body(body.to_vec())
            .send()
            .await
            .map_err(|e| (anyhow::Error::new(e).context("commit request failed"), true))?;
        let status = response.status();
        let bytes = response.bytes().await.map_err(|e| (anyhow::Error::new(e), true))?;
        if !status.is_success() {
            let retryable = status.as_u16() >= 500 || status.as_u16() == 429;
            return Err((
                anyhow::anyhow!(
                    "commit failed with status {}: {}",
                    status.as_u16(),
                    String::from_utf8_lossy(&bytes)
                ),
                retryable,
            ));
        }
        let parsed = CreateMediaItemsResponse::decode(bytes.as_ref()).map_err(|e| {
            (
                anyhow::Error::new(e).context("failed to parse accepted response"),
                false,
            )
        })?;
        parsed
            .item
            .iter()
            .filter_map(|item| item.result_item.as_ref())
            .map(|result| result.media_key.clone())
            .find(|key| !key.is_empty())
            .ok_or_else(|| (anyhow::anyhow!("upload rejected by API: media key is empty or missing"), false))
    }

    pub async fn create_album(&self, name: &str, media_keys: &[String]) -> Result<String> {
        use crate::core::proto::pb::create_album::field4_type::Field1Type as AlbumKey;
        use crate::core::proto::pb::create_album::{
            Field4Type as AlbumEntry, Field6Type, Field7Type, Field8Type,
        };
        use crate::core::proto::pb::CreateAlbum;
        use crate::core::proto::pb::CreateAlbumResponse;

        let message = CreateAlbum {
            album_name: name.to_string(),
            timestamp: now_unix(),
            field3: 1,
            media_keys: media_keys
                .iter()
                .map(|key| AlbumEntry {
                    field1: Some(AlbumKey {
                        media_key: key.clone(),
                    }),
                })
                .collect(),
            field6: Some(Field6Type {}),
            field7: Some(Field7Type { field1: 3 }),
            device_info: Some(Field8Type {
                model: MODEL.to_string(),
                make: MAKE.to_string(),
                android_api_version: ANDROID_API_VERSION,
            }),
        };
        let response = self
            .client
            .post(CREATE_ALBUM_ENDPOINT)
            .headers(self.protobuf_headers().await?)
            .header("x-goog-ext-173412678-bin", "CgcIAhClARgC")
            .header("x-goog-ext-174067345-bin", "CgIIAg==")
            .body(message.encode_to_vec())
            .send()
            .await?;
        let status = response.status();
        let bytes = response.bytes().await?;
        if !status.is_success() {
            bail!(
                "create album failed with status {}: {}",
                status.as_u16(),
                String::from_utf8_lossy(&bytes)
            );
        }
        let parsed = CreateAlbumResponse::decode(bytes.as_ref())?;
        parsed
            .field1
            .map(|f| f.album_media_key)
            .filter(|s| !s.is_empty())
            .context("create album failed: no album media key returned")
    }

    pub async fn add_media_to_album(&self, album_key: &str, media_keys: &[String]) -> Result<()> {
        use crate::core::proto::pb::add_media_to_album::{Field5Type, Field6Type};
        use crate::core::proto::pb::AddMediaToAlbum;
        let message = AddMediaToAlbum {
            media_keys: media_keys.to_vec(),
            album_media_key: album_key.to_string(),
            field5: Some(Field5Type { field1: 2 }),
            device_info: Some(Field6Type {
                model: MODEL.to_string(),
                make: MAKE.to_string(),
                android_api_version: ANDROID_API_VERSION,
            }),
            timestamp: now_unix(),
        };
        let response = self
            .client
            .post(ADD_MEDIA_TO_ALBUM_ENDPOINT)
            .headers(self.protobuf_headers().await?)
            .header("x-goog-ext-173412678-bin", "CgcIAhClARgC")
            .header("x-goog-ext-174067345-bin", "CgIIAg==")
            .body(message.encode_to_vec())
            .send()
            .await?;
        let status = response.status();
        if !status.is_success() {
            let bytes = response.bytes().await.unwrap_or_default();
            bail!(
                "add media to album failed with status {}: {}",
                status.as_u16(),
                String::from_utf8_lossy(&bytes)
            );
        }
        Ok(())
    }

    async fn protobuf_headers(&self) -> Result<reqwest::header::HeaderMap> {
        let bearer = self.bearer_token().await?;
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert("Accept-Encoding", "gzip".parse()?);
        headers.insert("Accept-Language", self.language.parse()?);
        headers.insert("Content-Type", "application/x-protobuf".parse()?);
        headers.insert("User-Agent", self.user_agent.parse()?);
        headers.insert(
            "Authorization",
            format!("Bearer {bearer}").parse()?,
        );
        Ok(headers)
    }
}

impl Api {
    /// True if this client can produce a bearer token for the loaded credential.
    pub async fn validate(&self) -> Result<()> {
        self.bearer_token().await?;
        let key = self.find_remote_media_by_hash(&[0u8; 20]).await?;
        if !key.is_empty() {
            bail!("unexpected media match for validation hash");
        }
        Ok(())
    }
}

pub type ProgressCallback = Arc<dyn Fn(i64, i64, i32) + Send + Sync>;

fn now_unix() -> i64 {
    chrono::Utc::now().timestamp()
}

fn backoff(attempt: usize) -> Duration {
    let base_ms = 1000_u64 * (1u64 << attempt.min(5));
    let base_ms = base_ms.min(30_000);
    let jitter = rand::random::<u64>() % (base_ms / 10).max(1);
    Duration::from_millis(base_ms + jitter)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_stays_bounded() {
        assert!(backoff(0) >= Duration::from_millis(1000));
        assert!(backoff(99) <= Duration::from_millis(33_000));
    }

    #[test]
    fn finalize_token_needs_the_expected_version() {
        let mut token = CommitToken {
            field1: 2,
            field2: b"opaque".to_vec(),
        };
        let valid = token.encode_to_vec();
        assert_eq!(valid[0], 0x08);
        assert_eq!(valid[1], 2);
        token.field1 = 1;
        assert_eq!(token.encode_to_vec()[1], 1);
    }
}
