//! 配对二维码：`thinktin-pair:v1?…` 画成图片给 egui 显示。

use egui::ColorImage;
use qrcode::{Color, QrCode};

/// 每个模块多少像素、四周留几个模块的空白。
const SCALE: usize = 6;
const QUIET: usize = 4;

pub fn image(uri: &str) -> Result<ColorImage, String> {
    let code = QrCode::new(uri.as_bytes()).map_err(|e| format!("cannot make a QR code: {e}"))?;
    let n = code.width();
    let colors = code.to_colors();
    let side = (n + 2 * QUIET) * SCALE;
    let mut rgb = vec![255u8; side * side * 3];
    for (i, c) in colors.iter().enumerate() {
        if *c != Color::Dark {
            continue;
        }
        let (mx, my) = (i % n + QUIET, i / n + QUIET);
        for y in my * SCALE..(my + 1) * SCALE {
            for x in mx * SCALE..(mx + 1) * SCALE {
                let at = (y * side + x) * 3;
                rgb[at..at + 3].copy_from_slice(&[0, 0, 0]);
            }
        }
    }
    Ok(ColorImage::from_rgb([side, side], &rgb))
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_code_is_square_with_a_quiet_zone() {
        let img = super::image("thinktin-pair:v1?d=abc&k=def&n=ghi&e=1").unwrap();
        assert_eq!(img.size[0], img.size[1]);
        // 角上是空白。
        assert_eq!(img.pixels[0], egui::Color32::WHITE);
        assert!(img.pixels.contains(&egui::Color32::BLACK));
    }
}
