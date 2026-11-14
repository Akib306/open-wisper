use std::path::{Path, PathBuf};
use wisper_core::{Model, Settings, Shortcut};

pub const SHORTCUTS: &[(&str, u32, u32)] = &[
    ("Command+Shift+Space", 49, 3),
    ("Option+Control+Space", 49, 12),
    ("Command+Shift+D", 2, 3),
    ("Command+Shift+V", 9, 3),
    ("Command+Shift+T", 17, 3),
    ("Command+Shift+S", 1, 3),
    ("Command+Shift+K", 40, 3),
    ("Command+Shift+L", 37, 3),
];

pub fn shortcut_name(shortcut: &Shortcut) -> Result<String, String> {
    let key = match shortcut.key_code {
        49 => "Space",
        2 => "D",
        9 => "V",
        17 => "T",
        1 => "S",
        40 => "K",
        37 => "L",
        _ => return Err("Unsupported shortcut key.".into()),
    };
    if shortcut.modifiers & !15 != 0 || shortcut.modifiers & 13 == 0 {
        return Err("Unsupported shortcut modifiers.".into());
    }
    let mut parts = Vec::new();
    for (bit, name) in [(1, "Command"), (2, "Shift"), (4, "Option"), (8, "Control")] {
        if shortcut.modifiers & bit != 0 {
            parts.push(name);
        }
    }
    parts.push(key);
    Ok(parts.join("+"))
}

pub fn profile_path(settings: &Settings, resources: &Path) -> Result<PathBuf, String> {
    settings.validate().map_err(|_| "Invalid settings.")?;
    let name = match settings.model {
        Model::Tiny => "tiny.en-q5_1",
        Model::Base => "base.en",
        Model::Small => "small.en",
        Model::Custom => return Ok(PathBuf::from(&settings.engine_profile_path)),
    };
    Ok(resources.join(format!("engine-profile-{name}.json")))
}

pub fn self_check() -> Result<(), String> {
    for (name, key_code, modifiers) in SHORTCUTS {
        let actual = shortcut_name(&Shortcut {
            key_code: *key_code,
            modifiers: *modifiers,
        })?;
        if actual != *name || actual.parse::<wisper_platform::hotkey::Shortcut>().is_err() {
            return Err("Shortcut mapping check failed.".into());
        }
    }
    let mut coordinator = wisper_core::SessionCoordinator::new();
    let stale = coordinator.start();
    coordinator.cancel();
    let current = coordinator.start();
    if coordinator.recording_started(stale) || !coordinator.recording_started(current) {
        return Err("Generation check failed.".into());
    }
    coordinator.stop();
    if !coordinator.audio_ready(current)
        || !coordinator.transcription_ready(current)
        || !coordinator.authorize_delivery(current)
        || coordinator.authorize_delivery(current)
    {
        return Err("Exactly-once delivery check failed.".into());
    }
    coordinator.cancel();
    if coordinator.authorize_delivery(current) {
        return Err("Cancellation check failed.".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shortcut_mapping_and_lifecycle() {
        self_check().unwrap();
        assert!(shortcut_name(&Shortcut {
            key_code: 0,
            modifiers: 3
        })
        .is_err());
        assert!(shortcut_name(&Shortcut {
            key_code: 49,
            modifiers: 2
        })
        .is_err());
    }

    #[test]
    fn models_resolve_without_fallback() {
        let root = Path::new("/fixture/Resources");
        let mut settings = Settings::default();
        assert_eq!(
            profile_path(&settings, root).unwrap(),
            root.join("engine-profile-base.en.json")
        );
        settings.model = Model::Tiny;
        assert_eq!(
            profile_path(&settings, root).unwrap(),
            root.join("engine-profile-tiny.en-q5_1.json")
        );
        settings.model = Model::Custom;
        assert!(profile_path(&settings, root).is_err());
        settings.engine_profile_path = "/custom/profile.json".into();
        assert_eq!(
            profile_path(&settings, root).unwrap(),
            Path::new("/custom/profile.json")
        );
    }
}
