mod policy;
mod storage;

#[cfg(target_os = "macos")]
mod app;

use std::path::PathBuf;
use wisper_core::{Cancellation, EngineManifest};

fn main() -> std::process::ExitCode {
    match entry() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("Open Wisper Rust: {message}");
            std::process::ExitCode::FAILURE
        }
    }
}

fn entry() -> Result<(), String> {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments == ["--self-check"] {
        policy::self_check()?;
        println!("Self-check passed (policy only; no native permissions or UI).");
        return Ok(());
    }
    if arguments.len() == 3 && arguments[0] == "--check-profile" && arguments[1] == "--profile" {
        EngineManifest::load_validated(&PathBuf::from(&arguments[2]), &Cancellation::new())
            .map_err(|_| "Engine profile validation failed.".to_owned())?;
        println!("Engine profile validated (engine and model SHA-256 checked).");
        return Ok(());
    }
    if !arguments.is_empty() {
        return Err("Usage: OpenWisperRust [--self-check | --check-profile --profile PATH]".into());
    }
    #[cfg(target_os = "macos")]
    return app::run();
    #[cfg(not(target_os = "macos"))]
    Err("The native application requires macOS 14 or later.".into())
}
