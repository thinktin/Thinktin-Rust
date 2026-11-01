//! 要用系统接口的小东西：DPAPI（会话和配对密钥的加密）、开机自启（注册表 Run 键）、系统语言。
//! 非 Windows 上是给开发用的替身（明文、不自启、英文）。

use std::path::Path;

/// 用当前 Windows 用户的 DPAPI 加密（只有这个用户、这台电脑能解）。
pub fn protect(plain: &[u8]) -> Result<Vec<u8>, String> {
    #[cfg(windows)]
    {
        dpapi::protect(plain)
    }
    #[cfg(not(windows))]
    {
        Ok(plain.to_vec())
    }
}

pub fn unprotect(blob: &[u8]) -> Result<Vec<u8>, String> {
    #[cfg(windows)]
    {
        dpapi::unprotect(blob)
    }
    #[cfg(not(windows))]
    {
        Ok(blob.to_vec())
    }
}

/// 注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 里有没有我们。
pub fn autostart_enabled() -> bool {
    #[cfg(windows)]
    {
        registry::autostart_enabled()
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// 登录 Windows 后在后台启动（`thinktin.exe --background`）。
pub fn set_autostart(exe: &Path, enabled: bool) -> Result<(), String> {
    #[cfg(windows)]
    {
        registry::set_autostart(exe, enabled)
    }
    #[cfg(not(windows))]
    {
        let _ = (exe, enabled);
        Err("autostart is only available on Windows".into())
    }
}

/// 起不来时给用户一个提示框（Windows 上没有控制台）。
pub fn fatal(message: &str) {
    #[cfg(windows)]
    {
        let text: Vec<u16> = message.encode_utf16().chain(std::iter::once(0)).collect();
        let title: Vec<u16> = "ThinkTin"
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        // SAFETY：字符串以 0 结尾，调用期间有效。
        unsafe {
            windows_sys::Win32::UI::WindowsAndMessaging::MessageBoxW(
                std::ptr::null_mut(),
                text.as_ptr(),
                title.as_ptr(),
                windows_sys::Win32::UI::WindowsAndMessaging::MB_ICONERROR,
            );
        }
    }
    eprintln!("{message}");
}

/// 系统界面语言是不是中文。
pub fn ui_language_is_chinese() -> bool {
    #[cfg(windows)]
    {
        // SAFETY：没有参数。
        let lang = unsafe { windows_sys::Win32::Globalization::GetUserDefaultUILanguage() };
        // 低 10 位是主语言；0x04 是中文。
        lang & 0x3ff == 0x04
    }
    #[cfg(not(windows))]
    {
        std::env::var("LANG").is_ok_and(|l| l.to_lowercase().starts_with("zh"))
    }
}

#[cfg(windows)]
mod dpapi {
    use std::ptr::{null, null_mut};

    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData, CryptUnprotectData,
    };

    fn blob(bytes: &[u8]) -> CRYPT_INTEGER_BLOB {
        CRYPT_INTEGER_BLOB {
            cbData: bytes.len() as u32,
            pbData: bytes.as_ptr().cast_mut(),
        }
    }

    /// 把系统分配的输出拷出来、释放。
    unsafe fn take(out: CRYPT_INTEGER_BLOB) -> Vec<u8> {
        // SAFETY：调用方保证 `out` 由 DPAPI 填好，指针有效且要用 `LocalFree` 释放。
        unsafe {
            let v = std::slice::from_raw_parts(out.pbData, out.cbData as usize).to_vec();
            LocalFree(out.pbData.cast());
            v
        }
    }

    pub fn protect(plain: &[u8]) -> Result<Vec<u8>, String> {
        let input = blob(plain);
        let mut out = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: null_mut(),
        };
        // SAFETY：按文档调用，输入在调用期间有效，输出由 `take` 释放。
        let ok = unsafe {
            CryptProtectData(
                &input,
                null(),
                null(),
                null(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut out,
            )
        };
        if ok == 0 {
            return Err("DPAPI cannot protect the data".into());
        }
        Ok(unsafe { take(out) })
    }

    pub fn unprotect(data: &[u8]) -> Result<Vec<u8>, String> {
        let input = blob(data);
        let mut out = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: null_mut(),
        };
        // SAFETY：同上。
        let ok = unsafe {
            CryptUnprotectData(
                &input,
                null_mut(),
                null(),
                null(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut out,
            )
        };
        if ok == 0 {
            return Err("DPAPI cannot read the data (another user or computer?)".into());
        }
        Ok(unsafe { take(out) })
    }
}

#[cfg(windows)]
mod registry {
    use std::path::Path;
    use std::ptr::null_mut;

    use windows_sys::Win32::System::Registry::{
        HKEY, HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_OPTION_NON_VOLATILE, REG_SZ,
        RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegQueryValueExW, RegSetValueExW,
    };

    const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
    const VALUE: &str = "ThinkTin";

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    fn open(access: u32) -> Result<HKEY, String> {
        let mut key: HKEY = null_mut();
        // SAFETY：按文档调用。
        let code = unsafe {
            RegCreateKeyExW(
                HKEY_CURRENT_USER,
                wide(RUN_KEY).as_ptr(),
                0,
                null_mut(),
                REG_OPTION_NON_VOLATILE,
                access,
                std::ptr::null(),
                &mut key,
                null_mut(),
            )
        };
        if code != 0 {
            return Err(format!("cannot open the Run key (error {code})"));
        }
        Ok(key)
    }

    pub fn autostart_enabled() -> bool {
        let Ok(key) = open(KEY_QUERY_VALUE) else {
            return false;
        };
        let mut size = 0u32;
        // SAFETY：只问值的大小。
        let code = unsafe {
            RegQueryValueExW(
                key,
                wide(VALUE).as_ptr(),
                std::ptr::null(),
                null_mut(),
                null_mut(),
                &mut size,
            )
        };
        unsafe { RegCloseKey(key) };
        code == 0
    }

    pub fn set_autostart(exe: &Path, enabled: bool) -> Result<(), String> {
        let key = open(KEY_SET_VALUE)?;
        let name = wide(VALUE);
        let code = if enabled {
            let command = wide(&format!("\"{}\" --background", exe.display()));
            // SAFETY：数据是以 0 结尾的 UTF-16，长度按字节传。
            unsafe {
                RegSetValueExW(
                    key,
                    name.as_ptr(),
                    0,
                    REG_SZ,
                    command.as_ptr().cast(),
                    (command.len() * 2) as u32,
                )
            }
        } else {
            // SAFETY：按文档调用。
            let code = unsafe { RegDeleteValueW(key, name.as_ptr()) };
            // 本来就没有也算成功（ERROR_FILE_NOT_FOUND = 2）。
            if code == 2 { 0 } else { code }
        };
        unsafe { RegCloseKey(key) };
        if code == 0 {
            Ok(())
        } else {
            Err(format!("cannot change the Run key (error {code})"))
        }
    }
}
