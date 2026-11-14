use crate::{MainThread, PlatformError};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Shortcut {
    key_code: u32,
    modifiers: u32,
}

impl Default for Shortcut {
    fn default() -> Self {
        Self {
            key_code: 49,
            modifiers: 256 | 512,
        }
    }
}

impl std::str::FromStr for Shortcut {
    type Err = PlatformError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let mut modifiers = 0;
        let mut key = None;
        for part in value.split('+') {
            let part = part.trim().to_ascii_lowercase();
            let modifier = match part.as_str() {
                "command" | "cmd" => 256,
                "shift" => 512,
                "option" | "alt" => 2048,
                "control" | "ctrl" => 4096,
                _ => 0,
            };
            if modifier != 0 {
                if modifiers & modifier != 0 {
                    return Err(PlatformError::InvalidShortcut);
                }
                modifiers |= modifier;
            } else {
                if key.is_some() {
                    return Err(PlatformError::InvalidShortcut);
                }
                key = Some(match part.as_str() {
                    "space" => 49,
                    "a" => 0,
                    "s" => 1,
                    "d" => 2,
                    "f" => 3,
                    "h" => 4,
                    "g" => 5,
                    "z" => 6,
                    "x" => 7,
                    "c" => 8,
                    "v" => 9,
                    "b" => 11,
                    "q" => 12,
                    "w" => 13,
                    "e" => 14,
                    "r" => 15,
                    "y" => 16,
                    "t" => 17,
                    "1" => 18,
                    "2" => 19,
                    "3" => 20,
                    "4" => 21,
                    "6" => 22,
                    "5" => 23,
                    "9" => 25,
                    "7" => 26,
                    "8" => 28,
                    "0" => 29,
                    "o" => 31,
                    "u" => 32,
                    "i" => 34,
                    "p" => 35,
                    "l" => 37,
                    "j" => 38,
                    "k" => 40,
                    "n" => 45,
                    "m" => 46,
                    _ => return Err(PlatformError::InvalidShortcut),
                });
            }
        }
        if modifiers & (256 | 2048 | 4096) == 0 {
            return Err(PlatformError::InvalidShortcut);
        }
        Ok(Self {
            key_code: key.ok_or(PlatformError::InvalidShortcut)?,
            modifiers,
        })
    }
}

pub struct GlobalHotkey {
    #[cfg(target_os = "macos")]
    native: crate::macos::NativeHotkey,
    _main: MainThread,
}

impl GlobalHotkey {
    pub fn new(main: &MainThread, shortcut: Shortcut) -> Result<Self, PlatformError> {
        #[cfg(target_os = "macos")]
        {
            Ok(Self {
                native: crate::macos::NativeHotkey::new(shortcut)?,
                _main: *main,
            })
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (main, shortcut);
            Err(PlatformError::Unsupported)
        }
    }

    pub fn replace(&mut self, shortcut: Shortcut) -> Result<(), PlatformError> {
        #[cfg(target_os = "macos")]
        {
            self.native.replace(shortcut)
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = shortcut;
            Err(PlatformError::Unsupported)
        }
    }

    pub fn take_pressed(&mut self) -> bool {
        #[cfg(target_os = "macos")]
        {
            self.native.take_pressed()
        }
        #[cfg(not(target_os = "macos"))]
        {
            false
        }
    }
}

impl Shortcut {
    #[cfg(target_os = "macos")]
    pub(crate) fn native_parts(self) -> (u32, u32) {
        (self.key_code, self.modifiers)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_default_and_rejects_ambiguous_shortcuts() {
        assert_eq!(
            "Command+Shift+Space".parse::<Shortcut>().unwrap(),
            Shortcut::default()
        );
        for invalid in [
            "Space",
            "Shift+Space",
            "Cmd+Cmd+Space",
            "Cmd+A+B",
            "Cmd+Return",
            "Cmd+",
        ] {
            assert!(invalid.parse::<Shortcut>().is_err(), "{invalid}");
        }
        assert!("Ctrl+Option+K".parse::<Shortcut>().is_ok());
    }
}
