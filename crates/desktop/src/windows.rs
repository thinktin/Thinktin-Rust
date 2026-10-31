//! Windows 上要用系统接口的工具（14.3、14.4 的 Windows 版），直接在 Rust 里用 Win32 实现，不经 UniFFI：
//! 截图（GDI `BitBlt` 主显示器）、键鼠（`SendInput`）、打开网页 / 程序 / 文件（`ShellExecuteW`）、前台程序
//! （`GetForegroundWindow` 所属进程的程序名，如 `chrome.exe`，就是手机授权里“应用”的写法）。
//! 文件和命令照旧由 [`crate::files::FileTools`] 做；删除进回收站的 [`recycle`] 也在这里。
//!
//! Windows 没有 macOS 那样的屏幕录制、辅助功能权限开关，所以这几个工具一直可用；管理员权限的窗口（UIPI）
//! 收不到普通进程发的输入，锁屏和 UAC 的安全桌面截不了图，这些在调用时报错。
//! 权限在调用前已经核对过（[`crate::policy`]），这里再守一条 macOS 端也守的：点击落在别的程序的窗口上时拒绝。

use std::ffi::c_void;
use std::mem::{size_of, zeroed};
use std::path::Path;
use std::ptr::{null, null_mut};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};
use windows_sys::Win32::Foundation::{CloseHandle, HWND, POINT};
use windows_sys::Win32::Graphics::Gdi::{
    BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BitBlt, CAPTUREBLT, CreateCompatibleDC, CreateDIBSection,
    DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDC, ReleaseDC, SRCCOPY, SelectObject,
};
use windows_sys::Win32::System::Threading::{
    OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
};
use windows_sys::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    INPUT, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP,
    KEYEVENTF_UNICODE, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP,
    MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEINPUT, MapVirtualKeyW,
    SendInput, VK_BACK, VK_CAPITAL, VK_CONTROL, VK_DELETE, VK_DOWN, VK_END, VK_ESCAPE, VK_F1,
    VK_HOME, VK_INSERT, VK_LEFT, VK_LWIN, VK_MENU, VK_NEXT, VK_PRIOR, VK_RETURN, VK_RIGHT,
    VK_SHIFT, VK_SNAPSHOT, VK_SPACE, VK_TAB, VK_UP, VkKeyScanW,
};
use windows_sys::Win32::UI::Shell::{
    FO_DELETE, FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT, SHFILEOPSTRUCTW,
    SHFileOperationW, ShellExecuteW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GA_ROOT, GetAncestor, GetForegroundWindow, GetSystemMetrics, GetWindowThreadProcessId,
    SM_CXSCREEN, SM_CYSCREEN, SW_SHOWNORMAL, WindowFromPoint,
};

use crate::keys::{Key, KeyCombo, NamedKey};
use crate::screenshot::{Geometry, encode_bgra};
use crate::{ToolBackend, ToolResult};

/// 这里实现的工具。
pub const NATIVE_TOOLS: [&str; 5] = [
    "computer_screenshot",
    "computer_click",
    "computer_type",
    "computer_key",
    "computer_open",
];

/// 打开就会运行的文件：`computer_open` 不开，让 agent 改用要手机批准的 `computer_run`。
const RUNS_WHEN_OPENED: &[&str] = &[
    "exe",
    "com",
    "bat",
    "cmd",
    "msi",
    "msp",
    "mst",
    "ps1",
    "psm1",
    "psd1",
    "vbs",
    "vbe",
    "js",
    "jse",
    "wsf",
    "wsh",
    "ws",
    "scr",
    "pif",
    "lnk",
    "url",
    "reg",
    "hta",
    "cpl",
    "msc",
    "jar",
    "inf",
    "scf",
    "appx",
    "msix",
    "appxbundle",
    "msixbundle",
    "application",
    "gadget",
    "vb",
    "sct",
    "shb",
    "shs",
    "py",
    "pyw",
    "rb",
    "pl",
    "diagcab",
    "iso",
    "img",
    "vhd",
    "vhdx",
];

/// 让这个进程按每个显示器的 DPI 算像素（截图和点击的坐标才是真实像素）。App 启动时调一次；
/// 已经由清单设置过时不会生效，也不要紧。
pub fn become_dpi_aware() {
    // SAFETY：只改本进程的设置，没有指针。
    unsafe {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 挪进回收站（`SHFileOperationW`，`FOF_ALLOWUNDO`）。路径要是去掉 `\\?\` 的绝对路径。
pub fn recycle(path: &Path) -> Result<(), String> {
    let s = path.to_string_lossy();
    // 列表以两个 0 结尾。
    let mut from: Vec<u16> = s.encode_utf16().collect();
    from.extend_from_slice(&[0, 0]);
    // SAFETY：结构体按文档填好，`from` 在调用期间一直有效。
    let code = unsafe {
        let mut op: SHFILEOPSTRUCTW = zeroed();
        op.wFunc = FO_DELETE;
        op.pFrom = from.as_ptr();
        op.fFlags = (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI) as u16;
        let code = SHFileOperationW(&mut op);
        if code == 0 && op.fAnyOperationsAborted != 0 {
            return Err("moving to the Recycle Bin was cancelled".into());
        }
        code
    };
    if code == 0 {
        Ok(())
    } else {
        Err(format!(
            "cannot move {} to the Recycle Bin (error {code:#x})",
            path.display()
        ))
    }
}

/// 一个窗口所属进程的程序名（小写，如 `chrome.exe`）和进程 id。
fn program_of(hwnd: HWND) -> Option<(u32, String)> {
    if hwnd.is_null() {
        return None;
    }
    // SAFETY：按文档调用，缓冲区大小随 `len` 传进去。
    unsafe {
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, &mut pid);
        if pid == 0 {
            return None;
        }
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return None;
        }
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(process, 0, buf.as_mut_ptr(), &mut len);
        CloseHandle(process);
        if ok == 0 {
            return None;
        }
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        let name = Path::new(&path)
            .file_name()?
            .to_string_lossy()
            .to_lowercase();
        Some((pid, name))
    }
}

/// 前台程序的程序名（手机授权里“应用”的写法）。
pub fn foreground_program() -> Option<String> {
    // SAFETY：没有参数。
    let hwnd = unsafe { GetForegroundWindow() };
    program_of(hwnd).map(|(_, name)| name)
}

fn screen_size() -> Result<(u32, u32), String> {
    // SAFETY：只读系统参数。
    let (w, h) = unsafe { (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)) };
    if w <= 0 || h <= 0 {
        return Err("cannot tell the screen size".into());
    }
    Ok((w as u32, h as u32))
}

/// 主显示器的位图（BGRA，自上而下）。
fn capture_primary() -> Result<(u32, u32, Vec<u8>), String> {
    let (w, h) = screen_size()?;
    // SAFETY：GDI 对象按建立的反序释放；DIB 的内存由 `CreateDIBSection` 分配，大小是 w*h*4，
    // 在 `DeleteObject` 之前拷走。
    unsafe {
        let screen = GetDC(null_mut());
        if screen.is_null() {
            return Err("cannot open the screen".into());
        }
        let dc = CreateCompatibleDC(screen);
        let mut info: BITMAPINFO = zeroed();
        info.bmiHeader = BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w as i32,
            biHeight: -(h as i32),
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            ..zeroed()
        };
        let mut bits: *mut c_void = null_mut();
        let bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &mut bits, null_mut(), 0);
        let result = if bitmap.is_null() || bits.is_null() {
            Err("cannot allocate the screenshot".to_owned())
        } else {
            let old = SelectObject(dc, bitmap);
            let ok = BitBlt(
                dc,
                0,
                0,
                w as i32,
                h as i32,
                screen,
                0,
                0,
                SRCCOPY | CAPTUREBLT,
            );
            SelectObject(dc, old);
            if ok == 0 {
                Err("cannot capture the screen (locked, or a secure desktop is showing)".to_owned())
            } else {
                let n = (w * h * 4) as usize;
                Ok(std::slice::from_raw_parts(bits as *const u8, n).to_vec())
            }
        };
        if !bitmap.is_null() {
            DeleteObject(bitmap);
        }
        DeleteDC(dc);
        ReleaseDC(null_mut(), screen);
        result.map(|bgra| (w, h, bgra))
    }
}

fn send(inputs: &[INPUT]) -> Result<(), String> {
    if inputs.is_empty() {
        return Ok(());
    }
    // SAFETY：数组和每个元素的大小按文档传。
    let sent = unsafe {
        SendInput(
            inputs.len() as u32,
            inputs.as_ptr(),
            size_of::<INPUT>() as i32,
        )
    };
    if sent as usize == inputs.len() {
        Ok(())
    } else {
        Err("the input was blocked (another program, or a window running as administrator, may be in front)".into())
    }
}

fn mouse(dx: i32, dy: i32, flags: u32) -> INPUT {
    // SAFETY：联合体先清零再填鼠标那一支。
    let mut input: INPUT = unsafe { zeroed() };
    input.r#type = INPUT_MOUSE;
    input.Anonymous.mi = MOUSEINPUT {
        dx,
        dy,
        mouseData: 0,
        dwFlags: flags,
        time: 0,
        dwExtraInfo: 0,
    };
    input
}

fn key(vk: u16, scan: u16, flags: u32) -> INPUT {
    // SAFETY：联合体先清零再填键盘那一支。
    let mut input: INPUT = unsafe { zeroed() };
    input.r#type = INPUT_KEYBOARD;
    input.Anonymous.ki = KEYBDINPUT {
        wVk: vk,
        wScan: scan,
        dwFlags: flags,
        time: 0,
        dwExtraInfo: 0,
    };
    input
}

/// 按一下（按下、松开）一个虚拟键。
fn tap(vk: u16, extended: bool) -> [INPUT; 2] {
    let scan = unsafe { MapVirtualKeyW(u32::from(vk), 0) } as u16;
    let ext = if extended { KEYEVENTF_EXTENDEDKEY } else { 0 };
    [key(vk, scan, ext), key(vk, scan, ext | KEYEVENTF_KEYUP)]
}

fn unicode(unit: u16) -> [INPUT; 2] {
    [
        key(0, unit, KEYEVENTF_UNICODE),
        key(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP),
    ]
}

/// 键名对应的虚拟键和它是不是扩展键（扩展键要带 `KEYEVENTF_EXTENDEDKEY`，不然有的程序认成小键盘）。
fn named_vk(k: NamedKey) -> (u16, bool) {
    match k {
        NamedKey::Return => (VK_RETURN, false),
        NamedKey::Tab => (VK_TAB, false),
        NamedKey::Space => (VK_SPACE, false),
        NamedKey::Escape => (VK_ESCAPE, false),
        NamedKey::Backspace => (VK_BACK, false),
        NamedKey::Delete => (VK_DELETE, true),
        NamedKey::Insert => (VK_INSERT, true),
        NamedKey::Up => (VK_UP, true),
        NamedKey::Down => (VK_DOWN, true),
        NamedKey::Left => (VK_LEFT, true),
        NamedKey::Right => (VK_RIGHT, true),
        NamedKey::Home => (VK_HOME, true),
        NamedKey::End => (VK_END, true),
        NamedKey::PageUp => (VK_PRIOR, true),
        NamedKey::PageDown => (VK_NEXT, true),
        NamedKey::F(n) => (VK_F1 + u16::from(n - 1), false),
        NamedKey::PrintScreen => (VK_SNAPSHOT, true),
        NamedKey::CapsLock => (VK_CAPITAL, false),
    }
}

/// 一个组合键的输入序列：修饰键按下、键按一下、修饰键反序松开。
fn combo_inputs(mut combo: KeyCombo) -> Result<Vec<INPUT>, String> {
    let (vk, extended) = match combo.key {
        Key::Named(k) => named_vk(k),
        Key::Char(c) => {
            let mut units = [0u16; 2];
            let encoded = c.encode_utf16(&mut units);
            if encoded.len() != 1 {
                return Err(format!(
                    "{c:?} cannot be pressed as a key; use computer_type"
                ));
            }
            // SAFETY：只是查表。
            let scan = unsafe { VkKeyScanW(encoded[0]) };
            if scan == -1 {
                return Err(format!(
                    "{c:?} is not on the current keyboard layout; use computer_type"
                ));
            }
            let vk = (scan & 0xff) as u16;
            let state = (scan >> 8) & 0xff;
            combo.shift |= state & 1 != 0;
            combo.ctrl |= state & 2 != 0;
            combo.alt |= state & 4 != 0;
            (vk, false)
        }
    };
    let mut mods: Vec<(u16, bool)> = Vec::new();
    if combo.ctrl {
        mods.push((VK_CONTROL, false));
    }
    if combo.shift {
        mods.push((VK_SHIFT, false));
    }
    if combo.alt {
        mods.push((VK_MENU, false));
    }
    if combo.meta {
        mods.push((VK_LWIN, true));
    }
    let mut inputs = Vec::new();
    for (m, ext) in &mods {
        inputs.push(tap(*m, *ext)[0]);
    }
    inputs.extend(tap(vk, extended));
    for (m, ext) in mods.iter().rev() {
        inputs.push(tap(*m, *ext)[1]);
    }
    Ok(inputs)
}

/// 屏幕像素换成 `SendInput` 的绝对坐标（0–65535 铺满主显示器）。
fn absolute(v: u32, extent: u32) -> i32 {
    if extent <= 1 {
        return 0;
    }
    ((u64::from(v) * 65535 + u64::from(extent - 1) / 2) / u64::from(extent - 1)) as i32
}

/// 最近一张截图的尺寸（点击坐标按它换算）。
type LastShot = Arc<Mutex<Option<Geometry>>>;

pub struct WindowsTools {
    geometry: LastShot,
}

impl Default for WindowsTools {
    fn default() -> Self {
        Self::new()
    }
}

impl WindowsTools {
    pub fn new() -> Self {
        Self {
            geometry: Arc::new(Mutex::new(None)),
        }
    }

    fn screenshot(last: &LastShot) -> Result<ToolResult, String> {
        let (w, h, bgra) = capture_primary()?;
        let (jpeg, geometry) = encode_bgra(w, h, &bgra)?;
        *last.lock().unwrap_or_else(|e| e.into_inner()) = Some(geometry);
        Ok(ToolResult {
            content: vec![json!({
                "type": "image",
                "data": STANDARD.encode(&jpeg),
                "mimeType": "image/jpeg",
            })],
            is_error: false,
        })
    }

    fn click(last: &LastShot, args: &Value) -> Result<ToolResult, String> {
        let coord = |name: &str| -> Result<u32, String> {
            args[name]
                .as_u64()
                .and_then(|v| u32::try_from(v).ok())
                .ok_or_else(|| format!("{name} is required"))
        };
        let (x, y) = (coord("x")?, coord("y")?);
        let right = match args["button"].as_str().unwrap_or("left") {
            "left" => false,
            "right" => true,
            other => return Err(format!("button must be left or right, not {other:?}")),
        };
        let double = args["double"].as_bool().unwrap_or(false);
        let (sw, sh) = screen_size()?;
        let geometry = last
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .unwrap_or(Geometry {
                image_width: sw,
                image_height: sh,
                screen_width: sw,
                screen_height: sh,
            });
        let (px, py) = geometry.to_screen(x, y);
        // 点到别的程序的窗口上就越权了：授权是按前台程序给的。桌面、什么都没有的地方不拦。
        // SAFETY：按文档调用。
        let under = unsafe {
            GetAncestor(
                WindowFromPoint(POINT {
                    x: px as i32,
                    y: py as i32,
                }),
                GA_ROOT,
            )
        };
        let front = unsafe { GetForegroundWindow() };
        if let (Some((under_pid, under_name)), Some((front_pid, _))) =
            (program_of(under), program_of(front))
            && under_pid != front_pid
        {
            return Err(format!(
                "that point is on a window of {under_name}, which is not the app in front; bring it to the front first (computer_open) or click inside the front app"
            ));
        }
        let (ax, ay) = (absolute(px, sw), absolute(py, sh));
        let (down, up) = if right {
            (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP)
        } else {
            (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP)
        };
        send(&[mouse(ax, ay, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE)])?;
        std::thread::sleep(Duration::from_millis(30));
        let clicks = if double { 2 } else { 1 };
        for i in 0..clicks {
            if i > 0 {
                std::thread::sleep(Duration::from_millis(60));
            }
            send(&[
                mouse(ax, ay, down | MOUSEEVENTF_ABSOLUTE),
                mouse(ax, ay, up | MOUSEEVENTF_ABSOLUTE),
            ])?;
        }
        Ok(ToolResult::text(format!(
            "{}clicked at ({x}, {y})",
            match (right, double) {
                (true, _) => "right-",
                (false, true) => "double-",
                (false, false) => "",
            }
        )))
    }

    fn type_text(args: &Value) -> Result<ToolResult, String> {
        let text = args["text"]
            .as_str()
            .ok_or_else(|| "text is required".to_owned())?;
        let mut batch: Vec<INPUT> = Vec::new();
        let flush = |batch: &mut Vec<INPUT>| -> Result<(), String> {
            send(batch)?;
            batch.clear();
            std::thread::sleep(Duration::from_millis(8));
            Ok(())
        };
        for c in text.chars() {
            match c {
                '\r' => continue,
                '\n' => batch.extend(tap(VK_RETURN, false)),
                '\t' => batch.extend(tap(VK_TAB, false)),
                c => {
                    let mut units = [0u16; 2];
                    for unit in c.encode_utf16(&mut units) {
                        batch.extend(unicode(*unit));
                    }
                }
            }
            if batch.len() >= 32 {
                flush(&mut batch)?;
            }
        }
        flush(&mut batch)?;
        Ok(ToolResult::text(format!(
            "typed {} characters",
            text.chars().count()
        )))
    }

    fn press(args: &Value) -> Result<ToolResult, String> {
        let spec = args["keys"]
            .as_str()
            .ok_or_else(|| "keys is required".to_owned())?;
        let combo = crate::keys::parse(spec)?;
        send(&combo_inputs(combo)?)?;
        Ok(ToolResult::text(format!("pressed {}", spec.trim())))
    }

    fn open(args: &Value) -> Result<ToolResult, String> {
        let target = args["target"]
            .as_str()
            .ok_or_else(|| "target is required".to_owned())?
            .trim();
        let what = if target.starts_with("https://") || target.starts_with("http://") {
            target.to_owned()
        } else if Path::new(target).is_absolute() {
            let path = crate::policy::resolve(Path::new(target))?;
            if !path.exists() {
                return Err(format!("{} does not exist", path.display()));
            }
            let ext = path
                .extension()
                .map(|e| e.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            if RUNS_WHEN_OPENED.contains(&ext.as_str()) {
                return Err(format!(
                    "{} would run when opened; use computer_run (the user approves it on their phone) instead",
                    path.display()
                ));
            }
            path.to_string_lossy().into_owned()
        } else {
            // 程序名：`chrome.exe`。不能带路径，不然就是在跑任意文件了。
            let lower = target.to_lowercase();
            if !lower.ends_with(".exe") || lower.contains(['\\', '/', ':']) {
                return Err(format!(
                    "{target:?} is not a web address, a program name like chrome.exe or an absolute path"
                ));
            }
            target.to_owned()
        };
        let file = wide(&what);
        let verb = wide("open");
        // SAFETY：字符串以 0 结尾，调用期间有效；返回值按文档大于 32 才算成功。
        let code = unsafe {
            ShellExecuteW(
                null_mut(),
                verb.as_ptr(),
                file.as_ptr(),
                null(),
                null(),
                SW_SHOWNORMAL,
            )
        } as usize;
        if code > 32 {
            Ok(ToolResult::text(format!("opened {what}")))
        } else {
            Err(format!("cannot open {what} (error {code})"))
        }
    }
}

#[async_trait]
impl ToolBackend for WindowsTools {
    fn available(&self) -> Vec<String> {
        NATIVE_TOOLS.iter().map(|t| t.to_string()).collect()
    }

    fn frontmost_app(&self) -> Option<String> {
        foreground_program()
    }

    async fn call(&self, tool: &str, arguments: &Value) -> ToolResult {
        let args = arguments.clone();
        let tool = tool.to_owned();
        let last = self.geometry.clone();
        let result = tokio::task::spawn_blocking(move || match tool.as_str() {
            "computer_screenshot" => Self::screenshot(&last),
            "computer_click" => Self::click(&last, &args),
            "computer_type" => Self::type_text(&args),
            "computer_key" => Self::press(&args),
            "computer_open" => Self::open(&args),
            other => Err(format!("{other} is not available on this computer")),
        })
        .await
        .unwrap_or_else(|e| Err(format!("the tool crashed: {e}")));
        result.unwrap_or_else(ToolResult::error)
    }
}
