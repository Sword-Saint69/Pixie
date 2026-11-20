//! gotohp-rs CLI. Shares the exact config file and Rust core with the GUI.
//! Usage mirrors the reference client's `gotohp-cli` where it matters.

use anyhow::{bail, Result};
use clap::{Parser, Subcommand};
use gotohp_core::core;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

#[derive(Parser)]
#[command(
    name = "gotohp-rs-cli",
    version,
    about = "Unofficial Google Photos uploader (Rust core)"
)]
struct Cli {
    /// Path to gotohp.config (portable file next to the executable wins by default)
    #[arg(short, long, global = true)]
    config: Option<PathBuf>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Upload files or directories
    Upload {
        paths: Vec<String>,
        #[arg(long)]
        recursive: bool,
        #[arg(long, default_value_t = 3)]
        threads: usize,
        #[arg(long)]
        force: bool,
        #[arg(long)]
        delete: bool,
        #[arg(long)]
        disable_filter: bool,
        #[arg(long)]
        set_date_from_filename: bool,
        #[arg(long)]
        exclude: Option<String>,
        #[arg(long)]
        album: Option<String>,
        #[arg(long)]
        album_auto: bool,
        #[arg(long)]
        account: Option<String>,
        #[arg(long)]
        proxy: Option<String>,
        #[arg(long)]
        saver: bool,
        #[arg(long)]
        use_quota: bool,
        /// Retry failed files automatically (default: on)
        #[arg(long, default_value_t = true)]
        retry: bool,
        #[arg(long, default_value_t = 2)]
        max_retries: u32,
    },
    /// Manage stored Google accounts
    Creds {
        #[command(subcommand)]
        action: CredsAction,
    },
    /// Show version information
    Version,
}

#[derive(Subcommand)]
enum CredsAction {
    /// Add an oauth_token cookie value or a raw credential query string
    Add {
        value: String,
        #[arg(long)]
        proxy: Option<String>,
    },
    /// List stored accounts
    List,
    /// Select the default account
    Set { email: String },
    /// Remove a stored account
    Remove { email: String },
}

fn main() {
    let cli = Cli::parse();
    if let Err(err) = run(cli) {
        eprintln!("Error: {err:#}");
        std::process::exit(1);
    }
}

fn run(cli: Cli) -> Result<()> {
    let store = Arc::new(core::config::ConfigStore::load(cli.config)?);
    if let Err(err) = core::embedded::ensure_embedded_account(&store) {
        eprintln!("embedded credential not installed: {err:#}");
    }
    match cli.command {
        Commands::Upload {
            paths,
            recursive,
            threads,
            force,
            delete,
            disable_filter,
            set_date_from_filename,
            exclude,
            album,
            album_auto,
            account,
            proxy,
            saver,
            use_quota,
            retry,
            max_retries,
        } => {
            if paths.is_empty() {
                bail!("provide at least one path");
            }
            let credential = store.credential_for(account.as_deref().unwrap_or(""))?;
            let mut prefs = store.preferences();
            prefs.recursive = recursive || prefs.recursive;
            prefs.upload_threads = threads as i32;
            prefs.force_upload = force || prefs.force_upload;
            prefs.delete_from_host = delete || prefs.delete_from_host;
            prefs.disable_unsupported_files_filter =
                disable_filter || prefs.disable_unsupported_files_filter;
            prefs.set_date_from_filename = set_date_from_filename || prefs.set_date_from_filename;
            if let Some(pattern) = exclude {
                prefs.exclude_pattern = pattern;
            }
            if let Some(p) = proxy {
                prefs.proxy = p;
            }
            prefs.saver = saver || prefs.saver;
            prefs.use_quota = use_quota || prefs.use_quota;

            let state = Arc::new(core::upload::UploadState::default());
            let options = core::upload::UploadOptions {
                credential,
                proxy: prefs.proxy.clone(),
                saver: prefs.saver,
                use_quota: prefs.use_quota,
                recursive: prefs.recursive,
                exclude_pattern: prefs.exclude_pattern.clone(),
                threads: threads.max(1),
                force_upload: prefs.force_upload,
                delete_from_host: prefs.delete_from_host,
                disable_unsupported_files_filter: prefs.disable_unsupported_files_filter,
                set_date_from_filename: prefs.set_date_from_filename,
                auto_retry: retry,
                max_auto_retries: max_retries as usize,
                album_name: album.unwrap_or_default(),
                album_auto,
            };
            core::upload::start_upload(state.clone(), paths, options)?;
            print_progress(&state);
            Ok(())
        }
        Commands::Creds { action } => match action {
            CredsAction::Add { value, proxy } => {
                let proxy = proxy.unwrap_or_else(|| store.preferences().proxy);
                let (credential, email) = if core::auth::looks_like_auth_string(&value) {
                    core::auth::validate_credential_shape(&value)?;
                    (
                        value.trim().to_string(),
                        core::auth::validate_credential_shape(&value)?,
                    )
                } else {
                    let android_id = core::auth::generate_android_id();
                    let exchange = core::runtime().block_on(
                        core::auth::exchange_embedded_setup_token(&value, &android_id, &proxy),
                    )?;
                    let cred = core::auth::build_google_photos_credential(
                        &exchange.email,
                        &exchange.master_token,
                        &android_id,
                    );
                    let api = core::api::Api::new(&cred, &proxy, false, false)?;
                    core::runtime().block_on(api.validate())?;
                    (cred, exchange.email)
                };
                let saved = store.upsert_credential(&credential)?;
                println!("Added {saved} ({email})");
                Ok(())
            }
            CredsAction::List => {
                let accounts = store.accounts();
                if accounts.is_empty() {
                    println!("No accounts stored.");
                }
                for account in accounts {
                    let marker = if account.email == store.selected() {
                        "*"
                    } else {
                        " "
                    };
                    let binding = if account.needs_token_binding {
                        " (needs token binding)"
                    } else {
                        ""
                    };
                    println!("{marker} {}{binding}", account.email);
                }
                Ok(())
            }
            CredsAction::Set { email } => {
                store.select_account(&email)?;
                println!("Selected {email}");
                Ok(())
            }
            CredsAction::Remove { email } => {
                store.remove_account(&email)?;
                println!("Removed {email}");
                Ok(())
            }
        },
        Commands::Version => {
            println!("gotohp-rs v{}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
    }
}

fn print_progress(state: &Arc<core::upload::UploadState>) {
    let mut done = 0;
    let mut total = 0;
    let mut last_length = 0usize;
    loop {
        let mut saw_stop = false;
        for event in state.drain_events() {
            match event.event_type.as_str() {
                "start" => {
                    total = event.total;
                    println!("Uploading {total} file(s)");
                }
                "thread" if !event.message.is_empty() => {
                    let line = format!(
                        "[{}] {}: {}",
                        event.worker_id, event.file_name, event.message
                    );
                    println!("{line}");
                    last_length = line.len();
                }
                "file_result" => {
                    done += 1;
                    let status = if event.is_error {
                        format!("ERROR {}", event.message)
                    } else if event.skipped {
                        format!("SKIPPED {}", event.skip_reason)
                    } else {
                        format!("OK {}", event.media_key)
                    };
                    println!("({done}/{total}) {}: {status}", event.file_path);
                    last_length = 0;
                }
                "album" => {
                    if event.is_error {
                        println!("Album '{}' failed: {}", event.message, event.skip_reason);
                    } else {
                        println!("Album '{}' created: {}", event.message, event.media_key);
                    }
                }
                "fatal" => println!("Fatal: {}", event.message),
                "stop" => saw_stop = true,
                _ => {}
            }
        }
        let _ = last_length;
        if saw_stop && !state.is_running() {
            break;
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    let summary = state.summary();
    println!(
        "Done: {} succeeded, {} skipped, {} failed",
        summary.succeeded, summary.skipped, summary.failed
    );
    if summary.failed > 0 {
        std::process::exit(2);
    }
}
