//! 托盘和窗口的图标：程序里画一个圆角方块加一个“T”（先不用设计稿，以后换成 .ico 资源）。
//! 颜色跟着状态变：灰（未连接）、蓝（已连接）、橙（正在被控制）。

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tone {
    Off,
    On,
    Active,
}

/// RGBA，`size × size`。
pub fn rgba(size: u32, tone: Tone) -> Vec<u8> {
    let fill = match tone {
        Tone::Off => [120u8, 124, 130],
        Tone::On => [47, 111, 237],
        Tone::Active => [240, 140, 30],
    };
    let s = size as f32;
    let radius = s * 0.22;
    let mut out = Vec::with_capacity((size * size * 4) as usize);
    for y in 0..size {
        for x in 0..size {
            let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
            // 圆角方块：到最近的角的距离。
            let cx = px.clamp(radius, s - radius);
            let cy = py.clamp(radius, s - radius);
            let inside = ((px - cx).powi(2) + (py - cy).powi(2)).sqrt() <= radius;
            // “T”：横在上面四分之一，竖在中间。
            let bar = py >= s * 0.26 && py <= s * 0.40 && px >= s * 0.24 && px <= s * 0.76;
            let stem = px >= s * 0.43 && px <= s * 0.57 && py >= s * 0.26 && py <= s * 0.78;
            let color = if !inside {
                [0, 0, 0, 0]
            } else if bar || stem {
                [255, 255, 255, 255]
            } else {
                [fill[0], fill[1], fill[2], 255]
            };
            out.extend_from_slice(&color);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn icons_have_transparent_corners_and_a_white_glyph() {
        let px = rgba(32, Tone::On);
        assert_eq!(px.len(), 32 * 32 * 4);
        assert_eq!(px[3], 0, "corner is transparent");
        let center = ((16 * 32 + 16) * 4) as usize;
        assert_eq!(&px[center..center + 4], &[255, 255, 255, 255]);
        let edge = ((16 * 32 + 3) * 4) as usize;
        assert_eq!(&px[edge..edge + 3], &[47, 111, 237]);
    }
}
