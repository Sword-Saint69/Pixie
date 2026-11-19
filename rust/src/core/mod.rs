pub mod api;
pub mod auth;
pub mod config;
pub mod embedded;
pub mod proto;
pub mod upload;

use std::sync::OnceLock;

/// One runtime shared by the Dart bridge and the CLI. Uploads run in the
/// background; the bridge itself only starts/cancels them and drains events.
pub fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .expect("build tokio runtime")
    })
}
