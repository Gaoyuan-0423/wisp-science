//! `view_image` helper — load a local image as a data URI for vision input.

use crate::env::{ImageData, ToolResult};
use base64::Engine;
use image::{imageops::FilterType, ImageFormat, ImageReader};
use std::{io::Cursor, path::Path};

pub const MAX_BYTES: usize = 5 * 1024 * 1024;
pub const RESIZE_CONFIRM_PREFIX: &str = "IMAGE_RESIZE_CONFIRM:";
const MAX_SOURCE_BYTES: usize = 50 * 1024 * 1024;
const MAX_DIMENSION: u32 = 2048;
const MAX_DECODE_DIMENSION: u32 = 32_768;
const IMAGE_EXTS: &[&str] = &["png", "jpg", "jpeg", "gif", "webp"];
const PNG_SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";

pub fn is_supported_image(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| IMAGE_EXTS.contains(&ext.to_ascii_lowercase().as_str()))
}

pub fn view_image(path: &str) -> ToolResult {
    view_image_inner(path, false)
}

pub fn view_image_resized(path: &str) -> ToolResult {
    view_image_inner(path, true)
}

/// Whether the source byte size requires the existing large-file confirmation.
/// Dimension-only resizing is automatic when preparing new model input.
pub fn needs_resize(path: &Path) -> Result<bool, String> {
    let size = std::fs::metadata(path)
        .map_err(|e| format!("cannot stat file: {e}"))?
        .len() as usize;
    if size > MAX_SOURCE_BYTES {
        return Err(format!(
            "image too large ({size} bytes, max source size {MAX_SOURCE_BYTES})"
        ));
    }
    Ok(size > MAX_BYTES)
}

fn view_image_inner(path: &str, resize_oversized: bool) -> ToolResult {
    if path.starts_with("http://") || path.starts_with("https://") {
        return ToolResult::fail(
            "view_image error: URL inputs are not supported. Download to a local file first.",
        );
    }
    let size = match std::fs::metadata(path) {
        Ok(m) => m.len() as usize,
        Err(e) => return ToolResult::fail(format!("view_image error: cannot stat file: {e}")),
    };
    if size == 0 {
        return ToolResult::fail("view_image error: image file is empty");
    }
    if size > MAX_BYTES && !resize_oversized {
        return ToolResult::fail(format!(
            "view_image error: image too large ({size} bytes, max {MAX_BYTES})"
        ));
    }
    if size > MAX_SOURCE_BYTES {
        return ToolResult::fail(format!(
            "view_image error: image too large ({size} bytes, max source size {MAX_SOURCE_BYTES})"
        ));
    }
    let ext = Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default();
    if !is_supported_image(Path::new(path)) {
        return ToolResult::fail(format!(
            "view_image error: unsupported image format '{ext}' (supported: png,jpg,jpeg,gif,webp)"
        ));
    }
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) => return ToolResult::fail(format!("view_image error: cannot read file: {e}")),
    };
    let (bytes, mime, resize_note) = match prepare_model_image(&bytes) {
        Ok(value) => value,
        Err(error) => return ToolResult::fail(format!("view_image error: {error}")),
    };
    let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let data_url = format!("data:{mime};base64,{b64}");
    let label = match resize_note {
        Some(note) => format!("Image: {path} ({note}; fine details may be lost)"),
        None => format!("Image: {path} ({size} bytes, {mime})"),
    };
    ToolResult::image(ImageData {
        mime: mime.into(),
        data_url,
        label,
    })
}

/// Keep the Scientific Illustrator contract on PNG even when a provider
/// returns JPEG (xAI Grok Imagine) or another raster format.
pub fn encode_as_png(bytes: &[u8]) -> Result<Vec<u8>, String> {
    if bytes.starts_with(PNG_SIGNATURE) {
        return Ok(bytes.to_vec());
    }
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|e| format!("cannot detect generated image format: {e}"))?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(MAX_DECODE_DIMENSION);
    limits.max_image_height = Some(MAX_DECODE_DIMENSION);
    limits.max_alloc = Some(256 * 1024 * 1024);
    reader.limits(limits);
    let image = reader
        .decode()
        .map_err(|e| format!("cannot decode generated image: {e}"))?;
    let mut output = Cursor::new(Vec::new());
    image
        .write_to(&mut output, ImageFormat::Png)
        .map_err(|e| format!("cannot encode generated PNG: {e}"))?;
    Ok(output.into_inner())
}

/// Validate new model input using its actual encoding, then bound both bytes
/// and dimensions. A highly compressible PNG can exceed provider pixel limits
/// while remaining far below MAX_BYTES. Callers retain their own source-size
/// approval/omission policy; this never changes the source file or history.
pub fn prepare_model_image(
    bytes: &[u8],
) -> Result<(Vec<u8>, &'static str, Option<String>), String> {
    if bytes.is_empty() || bytes.len() > MAX_SOURCE_BYTES {
        return Err(format!(
            "invalid image size ({} bytes; expected 1..={MAX_SOURCE_BYTES})",
            bytes.len()
        ));
    }
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|e| format!("cannot detect image format: {e}"))?;
    let mime = match reader.format() {
        Some(ImageFormat::Png) => "image/png",
        Some(ImageFormat::Jpeg) => "image/jpeg",
        Some(ImageFormat::Gif) => "image/gif",
        Some(ImageFormat::WebP) => "image/webp",
        _ => return Err("unsupported image content (supported: png,jpeg,gif,webp)".into()),
    };
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(MAX_DECODE_DIMENSION);
    limits.max_image_height = Some(MAX_DECODE_DIMENSION);
    limits.max_alloc = Some(256 * 1024 * 1024);
    reader.limits(limits);
    let image = reader
        .decode()
        .map_err(|e| format!("cannot decode image safely: {e}"))?;
    let (width, height) = (image.width(), image.height());
    if bytes.len() <= MAX_BYTES && width <= MAX_DIMENSION && height <= MAX_DIMENSION {
        return Ok((bytes.to_vec(), mime, None));
    }
    let resized = image.resize(MAX_DIMENSION, MAX_DIMENSION, FilterType::Lanczos3);
    let (new_width, new_height) = (resized.width(), resized.height());
    let mut output = Cursor::new(Vec::new());
    resized
        .to_rgb8()
        .write_to(&mut output, ImageFormat::Jpeg)
        .map_err(|e| format!("cannot encode resized image: {e}"))?;
    let output = output.into_inner();
    if output.len() > MAX_BYTES {
        return Err(format!(
            "resized image is still too large ({} bytes, max {MAX_BYTES})",
            output.len()
        ));
    }
    let output_len = output.len();
    Ok((
        output,
        "image/jpeg",
        Some(format!(
            "resized for model input from {width}x{height}, {} bytes to {new_width}x{new_height}, JPEG, {} bytes",
            bytes.len(),
            output_len
        )),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, Rgb, Rgba};

    #[test]
    fn small_file_with_9052_pixel_edge_is_resized_without_changing_source() {
        // Issue #1234: file-size checks alone allowed a 2236 x 9052 PNG.
        let source = ImageBuffer::from_pixel(2236, 9052, Rgba([20u8, 40, 60, 255]));
        let mut encoded = Cursor::new(Vec::new());
        source.write_to(&mut encoded, ImageFormat::Png).unwrap();
        let bytes = encoded.into_inner();
        assert!(bytes.len() < MAX_BYTES);
        let path = std::env::temp_dir().join(format!(
            "wisp-tall-image-{}-{}.png",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::write(&path, &bytes).unwrap();
        assert!(
            !needs_resize(&path).unwrap(),
            "no large-file approval needed"
        );
        let result = view_image(&path.to_string_lossy());
        let unchanged = std::fs::read(&path).unwrap();
        std::fs::remove_file(&path).unwrap();
        assert_eq!(unchanged, bytes);
        assert!(result.success, "{}", result.content);
        let image = &result.images[0];
        let data = image.data_url.split_once(',').unwrap().1;
        let output = base64::engine::general_purpose::STANDARD
            .decode(data)
            .unwrap();
        let decoded = image::load_from_memory(&output).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (506, 2048));
        assert!(output.len() <= MAX_BYTES);
        assert_eq!(image.mime, "image/jpeg");
        assert!(image.label.contains("2236x9052"));
        assert!(image.label.contains("fine details may be lost"));
    }

    #[test]
    fn small_supported_images_preserve_encoding_and_bytes() {
        let source =
            image::DynamicImage::ImageRgb8(ImageBuffer::from_pixel(4, 3, Rgb([1u8, 2, 3])));
        for (format, expected_mime) in [
            (ImageFormat::Png, "image/png"),
            (ImageFormat::Jpeg, "image/jpeg"),
            (ImageFormat::Gif, "image/gif"),
            (ImageFormat::WebP, "image/webp"),
        ] {
            let mut encoded = Cursor::new(Vec::new());
            source.write_to(&mut encoded, format).unwrap();
            let (bytes, mime, note) = prepare_model_image(encoded.get_ref()).unwrap();
            assert_eq!(&bytes, encoded.get_ref());
            assert_eq!(mime, expected_mime);
            assert!(note.is_none());
        }
    }

    #[test]
    fn malformed_or_truncated_image_is_rejected_before_model_input() {
        for bytes in [
            b"<html>download failed</html>".as_slice(),
            PNG_SIGNATURE,
            b"",
        ] {
            assert!(prepare_model_image(bytes).is_err());
        }
        let source = ImageBuffer::from_pixel(10, 10, Rgb([1u8, 2, 3]));
        let mut encoded = Cursor::new(Vec::new());
        source.write_to(&mut encoded, ImageFormat::Png).unwrap();
        assert!(prepare_model_image(&encoded.get_ref()[..40]).is_err());
    }

    #[test]
    fn oversized_image_is_resized_to_bounded_model_input() {
        let source = ImageBuffer::from_fn(2400, 2200, |x, y| {
            let n = x
                .wrapping_mul(1_664_525)
                .wrapping_add(y.wrapping_mul(1_013_904_223));
            Rgba([(n >> 16) as u8, (n >> 8) as u8, n as u8, 255])
        });
        let mut encoded = Cursor::new(Vec::new());
        source.write_to(&mut encoded, ImageFormat::Png).unwrap();
        assert!(encoded.get_ref().len() > MAX_BYTES);

        let (resized, mime, note) = prepare_model_image(encoded.get_ref()).unwrap();
        let decoded = image::load_from_memory(&resized).unwrap();
        assert_eq!(mime, "image/jpeg");
        assert!(decoded.width() <= MAX_DIMENSION && decoded.height() <= MAX_DIMENSION);
        assert!(resized.len() <= MAX_BYTES);
        assert!(note.unwrap().contains("resized for model input"));
    }

    #[test]
    fn jpeg_is_reencoded_as_png() {
        let source = ImageBuffer::from_pixel(1, 1, Rgb([10u8, 20, 30]));
        let mut jpeg = Cursor::new(Vec::new());
        source.write_to(&mut jpeg, ImageFormat::Jpeg).unwrap();
        let png = encode_as_png(jpeg.get_ref()).unwrap();
        assert!(png.starts_with(PNG_SIGNATURE));
        assert_eq!(encode_as_png(&png).unwrap(), png);
    }
}
