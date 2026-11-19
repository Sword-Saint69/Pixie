//! Build-time embedded credential. The user supplied this credential from an
//! ADB logcat capture of the Google Photos GmsCore auth request; the only edit
//! is `androidId=null` -> the real ID read from the connected device.

use crate::core::auth::validate_credential_shape;
use crate::core::config::ConfigStore;
use anyhow::Result;

pub const EMBEDDED_ANDROID_ID: &str = "337723ec77fb883f";

pub const EMBEDDED_CREDENTIAL: &str = r#"androidId=337723ec77fb883f&app=com.google.android.apps.photos&client_sig=24bb24c05e47e0aefa68a58a766179d9b613a600&callerPkg=com.google.android.apps.photos&callerSig=24bb24c05e47e0aefa68a58a766179d9b613a600&device_country=in&Email=gouthamsankarjl%40gmail.com&google_play_services_version=250932000&lang=en_IN&oauth2_foreground=1&operatorCountry=in&sdk_version=36&service=oauth2%3Aopenid%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fmobileapps.native%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fphotos.native&source=android&Token=aas_et%2FAKppINYSGtHrNOYcEoWZ1UPp6KpWtKVskpfCqS07HBSl_xGTRa4dCQ6KrTWoxcvtm8Pco5B9uWlk-m_Kl7hlQkSzsD6JqpAJO2jCWTBzwr7HHRjfUzb5M-lSxOHUQCx5FxHKrC9_-yMexvNC_kaHC5uswOpRqaJ0iXm9CP1DIiRpO9gBaNeZNcMKyrrkFAOvkGabSsoIJWeW9twMYHb4wR0%3D"#;

/// Validates the embedded string and returns it.
pub fn embedded_credential() -> Result<String> {
    validate_credential_shape(EMBEDDED_CREDENTIAL)?;
    Ok(EMBEDDED_CREDENTIAL.to_string())
}

/// Makes sure the embedded account exists in the config store and is selected.
/// A stale copy with the same email is replaced on every startup, which keeps
/// the hardcoded token authoritative after a re-capture.
pub fn ensure_embedded_account(store: &ConfigStore) -> Result<String> {
    let credential = embedded_credential()?;
    store.upsert_credential(&credential)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::config::parse_query;

    #[test]
    fn embedded_credential_is_complete() {
        let params = parse_query(EMBEDDED_CREDENTIAL);
        assert_eq!(params["androidId"], EMBEDDED_ANDROID_ID);
        assert_eq!(params["Email"], "gouthamsankarjl@gmail.com");
        assert_eq!(params["lang"], "en_IN");
        assert!(params["Token"].starts_with("aas_et/"));
        assert!(embedded_credential().is_ok());
    }
}
