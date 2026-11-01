//! 截图的编码：系统接口给出的位图缩到长边最多 [`MAX_EDGE`] 像素、编成 JPEG，并记住图片像素和屏幕像素的换算
//! （`computer_click` 的坐标是最近一张截图的像素）。和平台无关，截取本身在各平台的模块里。

use jpeg_encoder::{ColorType, Encoder};

/// 长边最多多少像素（和 macOS 端一样）。
pub const MAX_EDGE: u32 = 1568;
/// JPEG 质量。
pub const QUALITY: u8 = 80;

/// 最近一张截图的尺寸和它对应的屏幕尺寸。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Geometry {
    pub image_width: u32,
    pub image_height: u32,
    pub screen_width: u32,
    pub screen_height: u32,
}

impl Geometry {
    /// 图片像素换成屏幕像素（四舍五入，不出屏幕）。
    pub fn to_screen(&self, x: u32, y: u32) -> (u32, u32) {
        let scale = |v: u32, from: u32, to: u32| -> u32 {
            if from == 0 || from == to {
                return v.min(to.saturating_sub(1));
            }
            let s = (u64::from(v) * u64::from(to) + u64::from(from) / 2) / u64::from(from);
            (s as u32).min(to.saturating_sub(1))
        };
        (
            scale(x, self.image_width, self.screen_width),
            scale(y, self.image_height, self.screen_height),
        )
    }
}

/// 缩小后的尺寸：长边最多 `max_edge`，等比。
pub fn fit(width: u32, height: u32, max_edge: u32) -> (u32, u32) {
    let long = width.max(height);
    if long <= max_edge || long == 0 {
        return (width, height);
    }
    let w = (u64::from(width) * u64::from(max_edge) / u64::from(long)).max(1) as u32;
    let h = (u64::from(height) * u64::from(max_edge) / u64::from(long)).max(1) as u32;
    (w, h)
}

/// BGRA（Windows 的 32 位 DIB，一行 `width * 4` 字节）缩到 `(dw, dh)` 并转成 RGB：每个目标像素取它覆盖的源像素的平均。
pub fn shrink_bgra_to_rgb(width: u32, height: u32, bgra: &[u8], dw: u32, dh: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity((dw * dh * 3) as usize);
    let (sw, sh) = (width as usize, height as usize);
    let stride = sw * 4;
    for dy in 0..dh as usize {
        let y0 = dy * sh / dh as usize;
        let y1 = (((dy + 1) * sh) / dh as usize).max(y0 + 1).min(sh);
        for dx in 0..dw as usize {
            let x0 = dx * sw / dw as usize;
            let x1 = (((dx + 1) * sw) / dw as usize).max(x0 + 1).min(sw);
            let (mut r, mut g, mut b, mut n) = (0u64, 0u64, 0u64, 0u64);
            for y in y0..y1 {
                let row = &bgra[y * stride..];
                for x in x0..x1 {
                    let p = &row[x * 4..x * 4 + 4];
                    b += u64::from(p[0]);
                    g += u64::from(p[1]);
                    r += u64::from(p[2]);
                    n += 1;
                }
            }
            let n = n.max(1);
            out.extend_from_slice(&[(r / n) as u8, (g / n) as u8, (b / n) as u8]);
        }
    }
    out
}

/// 一张 BGRA 位图编成 JPEG（长边最多 [`MAX_EDGE`]），带上像素换算。
pub fn encode_bgra(width: u32, height: u32, bgra: &[u8]) -> Result<(Vec<u8>, Geometry), String> {
    if width == 0 || height == 0 || bgra.len() < (width * height * 4) as usize {
        return Err("the screenshot is empty".into());
    }
    let (dw, dh) = fit(width, height, MAX_EDGE);
    let rgb = shrink_bgra_to_rgb(width, height, bgra, dw, dh);
    let mut jpeg = Vec::new();
    Encoder::new(&mut jpeg, QUALITY)
        .encode(&rgb, dw as u16, dh as u16, ColorType::Rgb)
        .map_err(|e| format!("cannot encode the screenshot: {e}"))?;
    Ok((
        jpeg,
        Geometry {
            image_width: dw,
            image_height: dh,
            screen_width: width,
            screen_height: height,
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes_fit_and_coordinates_map_back() {
        assert_eq!(fit(3840, 2160, 1568), (1568, 882));
        assert_eq!(fit(1000, 2000, 1568), (784, 1568));
        assert_eq!(fit(800, 600, 1568), (800, 600));
        let g = Geometry {
            image_width: 1568,
            image_height: 882,
            screen_width: 3840,
            screen_height: 2160,
        };
        assert_eq!(g.to_screen(0, 0), (0, 0));
        assert_eq!(g.to_screen(784, 441), (1920, 1080));
        assert_eq!(g.to_screen(1567, 881), (3838, 2158));
        // 出了图片范围就夹在屏幕里。
        assert_eq!(g.to_screen(9999, 9999), (3839, 2159));
        let same = Geometry {
            image_width: 800,
            image_height: 600,
            screen_width: 800,
            screen_height: 600,
        };
        assert_eq!(same.to_screen(10, 20), (10, 20));
    }

    #[test]
    fn bitmaps_shrink_and_encode() {
        // 4×2 的图：左半红、右半蓝（BGRA），缩成 2×1 应当是一个红一个蓝。
        let mut bgra = Vec::new();
        for _ in 0..2 {
            for x in 0..4 {
                bgra.extend_from_slice(if x < 2 {
                    &[0, 0, 255, 255]
                } else {
                    &[255, 0, 0, 255]
                });
            }
        }
        assert_eq!(
            shrink_bgra_to_rgb(4, 2, &bgra, 2, 1),
            vec![255, 0, 0, 0, 0, 255]
        );
        let (jpeg, g) = encode_bgra(4, 2, &bgra).unwrap();
        assert_eq!(&jpeg[..2], &[0xFF, 0xD8], "JPEG magic");
        assert_eq!((g.image_width, g.image_height), (4, 2));
        assert!(encode_bgra(0, 0, &[]).is_err());
        assert!(encode_bgra(4, 2, &bgra[..8]).is_err());
    }
}
