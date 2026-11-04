//! `computer_key` 的按键写法：`return`、`ctrl+s`、`cmd+shift+t`、`win+e`。解析和平台无关，按成什么键由各平台决定
//! （macOS 在 App 的 `KeyCombination` 里，Windows 在 [`crate::windows`]）。

/// 一个组合键：修饰键加一个键。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyCombo {
    pub ctrl: bool,
    pub shift: bool,
    pub alt: bool,
    /// macOS 的 command，Windows 的 win 键。
    pub meta: bool,
    pub key: Key,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Key {
    /// 一个字符（字母按小写给；大写字母等于加 shift，由平台处理）。
    Char(char),
    Named(NamedKey),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NamedKey {
    Return,
    Tab,
    Space,
    Escape,
    Backspace,
    Delete,
    Insert,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    /// F1–F24。
    F(u8),
    PrintScreen,
    CapsLock,
}

fn named(token: &str) -> Option<NamedKey> {
    Some(match token {
        "return" | "enter" => NamedKey::Return,
        "tab" => NamedKey::Tab,
        "space" | "spacebar" => NamedKey::Space,
        "esc" | "escape" => NamedKey::Escape,
        "backspace" | "bs" => NamedKey::Backspace,
        "delete" | "del" | "forwarddelete" => NamedKey::Delete,
        "insert" | "ins" => NamedKey::Insert,
        "up" | "uparrow" | "arrowup" => NamedKey::Up,
        "down" | "downarrow" | "arrowdown" => NamedKey::Down,
        "left" | "leftarrow" | "arrowleft" => NamedKey::Left,
        "right" | "rightarrow" | "arrowright" => NamedKey::Right,
        "home" => NamedKey::Home,
        "end" => NamedKey::End,
        "pageup" | "pgup" => NamedKey::PageUp,
        "pagedown" | "pgdn" => NamedKey::PageDown,
        "printscreen" | "prtsc" => NamedKey::PrintScreen,
        "capslock" => NamedKey::CapsLock,
        t => {
            let n: u8 = t.strip_prefix('f')?.parse().ok()?;
            if (1..=24).contains(&n) {
                NamedKey::F(n)
            } else {
                return None;
            }
        }
    })
}

/// 解析 `ctrl+shift+t` 这类写法：`+` 分隔，不分大小写，修饰键可以叫 ctrl / control、shift、alt / option、
/// cmd / command / win / super / meta；最后一个是键，可以是一个字符或者键名（`return`、`f5`、`pageup`……）。
/// `+` 键本身写成 `ctrl++` 或者 `plus`。
pub fn parse(spec: &str) -> Result<KeyCombo, String> {
    let spec = spec.trim();
    if spec.is_empty() {
        return Err("keys is required".into());
    }
    // 结尾的 `+` 是加号键：`ctrl++`、`+`。
    let (body, plus_key) = match spec.strip_suffix('+') {
        Some(rest) => (rest.strip_suffix('+').unwrap_or(rest), true),
        None => (spec, false),
    };
    let mut combo = KeyCombo {
        ctrl: false,
        shift: false,
        alt: false,
        meta: false,
        key: Key::Char('+'),
    };
    let mut tokens: Vec<String> = body
        .split('+')
        .map(|t| t.trim().to_lowercase())
        .filter(|t| !t.is_empty())
        .collect();
    let key = if plus_key {
        Key::Char('+')
    } else {
        let last = tokens
            .pop()
            .ok_or_else(|| format!("{spec:?} names no key"))?;
        match last.as_str() {
            "plus" => Key::Char('+'),
            "minus" | "hyphen" => Key::Char('-'),
            t => {
                let mut chars = t.chars();
                match (chars.next(), chars.next()) {
                    (Some(c), None) => Key::Char(c),
                    _ => Key::Named(named(t).ok_or_else(|| format!("{t:?} is not a key I know"))?),
                }
            }
        }
    };
    for m in tokens {
        match m.as_str() {
            "ctrl" | "control" | "ctl" => combo.ctrl = true,
            "shift" => combo.shift = true,
            "alt" | "option" | "opt" => combo.alt = true,
            "cmd" | "command" | "win" | "windows" | "super" | "meta" => combo.meta = true,
            other => return Err(format!("{other:?} is not a modifier key")),
        }
    }
    combo.key = key;
    Ok(combo)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn combinations_parse() {
        let c = parse("Ctrl+Shift+T").unwrap();
        assert!(c.ctrl && c.shift && !c.alt && !c.meta);
        assert_eq!(c.key, Key::Char('t'));
        assert_eq!(parse("return").unwrap().key, Key::Named(NamedKey::Return));
        assert_eq!(parse("F5").unwrap().key, Key::Named(NamedKey::F(5)));
        assert_eq!(
            parse("cmd+pageup").unwrap(),
            KeyCombo {
                ctrl: false,
                shift: false,
                alt: false,
                meta: true,
                key: Key::Named(NamedKey::PageUp)
            }
        );
        assert!(parse("win+e").unwrap().meta);
        assert!(parse("option+left").unwrap().alt);
        assert_eq!(parse("ctrl++").unwrap().key, Key::Char('+'));
        assert_eq!(parse("+").unwrap().key, Key::Char('+'));
        assert_eq!(parse("ctrl+plus").unwrap().key, Key::Char('+'));
        assert_eq!(parse("ctrl+-").unwrap().key, Key::Char('-'));
        assert_eq!(parse(" 中 ").unwrap().key, Key::Char('中'));
        assert!(parse("").is_err());
        assert!(parse("ctrl+").is_err() || parse("ctrl+").unwrap().key == Key::Char('+'));
        assert!(parse("hyper+a").is_err());
        assert!(parse("f25").is_err());
        assert!(parse("ctrl+shift").is_err());
    }
}
