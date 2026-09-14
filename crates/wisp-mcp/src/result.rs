//! Deliberate MCP -> model projection. The raw result remains available to
//! Apps; model context must never inherit App-only `_meta` or binary blobs.

use base64::Engine;
use serde_json::{json, Value};
use wisp_tools::{ImageData, ToolResult};

use crate::McpCallResult;

const MAX_IMAGES: usize = 8;
const MAX_TOTAL_IMAGE_BYTES: usize = 20 * 1024 * 1024;

fn model_visible(block: &Value) -> bool {
    block
        .pointer("/annotations/audience")
        .and_then(Value::as_array)
        .is_none_or(|audience| {
            audience
                .iter()
                .any(|role| role.as_str() == Some("assistant"))
        })
}

/// Preserve text, structured facts, images and resource references without
/// fetching a URI, executing an artifact, or turning tool errors into success.
pub fn model_result(result: &McpCallResult) -> ToolResult {
    let mut text = Vec::new();
    let mut images = Vec::new();
    let mut total_image_bytes = 0;
    for (index, block) in result.content.iter().enumerate() {
        if !model_visible(block) {
            continue;
        }
        match block.get("type").and_then(Value::as_str) {
            Some("text") => {
                if let Some(value) = block.get("text").and_then(Value::as_str) {
                    text.push(value.to_string());
                }
            }
            Some("image") => {
                match model_image(block, index, images.len(), &mut total_image_bytes) {
                    Ok(image) => {
                        text.push(image.label.clone());
                        images.push(image);
                    }
                    Err(reason) => text.push(format!(
                        "[MCP image at content[{index}] not delivered to the model: {reason}; no visual inspection was performed for this image.]"
                    )),
                }
            }
            Some("resource_link") => {
                // A link is a reference, not permission to fetch it.
                text.push(format!("MCP resource link: {}", json!({
                    "uri": block.get("uri"),
                    "name": block.get("name"),
                    "description": block.get("description"),
                    "mimeType": block.get("mimeType"),
                })));
            }
            Some("resource") => {
                if let Some(resource) = block.get("resource") {
                    text.push(format!("MCP embedded resource: {}", json!({
                        "uri": resource.get("uri"),
                        "mimeType": resource.get("mimeType"),
                        "text": resource.get("text"),
                    })));
                    if resource.get("blob").is_some() {
                        text.push("[Embedded binary resource not delivered to the model.]".into());
                    }
                }
            }
            _ => text.push(format!(
                "[Unsupported MCP content at index {index} not delivered to the model.]"
            )),
        }
    }
    if let Some(structured) = &result.structured_content {
        // Some servers already serialize the same object in a text block.
        if !text
            .iter()
            .any(|value| serde_json::from_str::<Value>(value).ok().as_ref() == Some(structured))
        {
            text.push(format!("MCP structuredContent: {structured}"));
        }
    }
    let content = if text.is_empty() {
        "(no model-visible output)".to_string()
    } else {
        text.join("\n")
    };
    let mut output = if result.is_error {
        ToolResult::fail(content)
    } else {
        ToolResult::ok(content)
    };
    output.images = images;
    output
}

fn model_image(
    block: &Value,
    index: usize,
    image_count: usize,
    total_bytes: &mut usize,
) -> Result<ImageData, String> {
    if image_count >= MAX_IMAGES {
        return Err("image-count limit exceeded".into());
    }
    let mime = block.get("mimeType").and_then(Value::as_str).unwrap_or("");
    if !matches!(
        mime,
        "image/png" | "image/jpeg" | "image/gif" | "image/webp"
    ) {
        return Err("unsupported MIME type".into());
    }
    let data = block
        .get("data")
        .and_then(Value::as_str)
        .ok_or("missing base64 data")?;
    if data.len() > wisp_tools::image::MAX_BYTES.div_ceil(3) * 4 {
        return Err("image-size limit exceeded".into());
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|_| "invalid base64 data")?;
    if bytes.is_empty() {
        return Err("empty image".into());
    }
    if bytes.len() > wisp_tools::image::MAX_BYTES
        || total_bytes.saturating_add(bytes.len()) > MAX_TOTAL_IMAGE_BYTES
    {
        return Err("image-size limit exceeded".into());
    }
    let (bytes, mime, resize_note) = wisp_tools::image::prepare_model_image(&bytes)?;
    if total_bytes.saturating_add(bytes.len()) > MAX_TOTAL_IMAGE_BYTES {
        return Err("image-size limit exceeded".into());
    }
    *total_bytes += bytes.len();
    let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let mut label = format!("MCP image at content[{index}] ({mime})");
    if let Some(note) = resize_note {
        label.push_str(&format!(" ({note}; fine details may be lost)"));
    }
    Ok(ImageData {
        mime: mime.into(),
        data_url: format!("data:{mime};base64,{data}"),
        label,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png_data(width: u32, height: u32) -> String {
        let image = image::ImageBuffer::from_pixel(width, height, image::Rgb([1u8, 2, 3]));
        let mut output = std::io::Cursor::new(Vec::new());
        image
            .write_to(&mut output, image::ImageFormat::Png)
            .unwrap();
        base64::engine::general_purpose::STANDARD.encode(output.into_inner())
    }

    #[test]
    fn small_mcp_file_with_oversized_width_is_normalized_and_raw_result_preserved() {
        let data = png_data(9052, 20);
        let input = result(vec![
            json!({"type": "image", "mimeType": "image/png", "data": data}),
        ]);
        let output = model_result(&input);
        assert_eq!(output.images.len(), 1, "{}", output.content);
        let image = &output.images[0];
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(image.data_url.split_once(',').unwrap().1)
            .unwrap();
        let decoded = image::load_from_memory(&bytes).unwrap();
        assert_eq!(decoded.width(), 2048);
        assert!(decoded.height() <= 2048);
        assert_eq!(image.mime, "image/jpeg");
        assert!(output.content.contains("9052x20"));
        assert!(output.content.contains("fine details may be lost"));
        assert_eq!(input.content[0]["data"], data);
    }

    #[test]
    fn mcp_image_mime_comes_from_decoded_content() {
        let output = model_result(&result(vec![json!({
            "type": "image", "mimeType": "image/jpeg", "data": png_data(1, 1)
        })]));
        assert_eq!(output.images[0].mime, "image/png");
        assert!(output.images[0]
            .data_url
            .starts_with("data:image/png;base64,"));
    }

    fn result(content: Vec<Value>) -> McpCallResult {
        McpCallResult {
            content,
            structured_content: Some(json!({"planDigest": "exact-digest", "terminal": true})),
            meta: Some(json!({"privateAppState": "must-not-reach-model"})),
            is_error: false,
        }
    }

    #[test]
    fn mixed_result_keeps_text_images_structure_and_error_but_not_private_meta() {
        let mut input = result(vec![
            json!({"type": "text", "text": "TERMINAL: true\nNEXT_ACTION: ask_user"}),
            json!({"type": "image", "mimeType": "image/png", "data": png_data(1, 1)}),
            json!({"type": "image", "mimeType": "image/png", "data": png_data(2, 1)}),
        ]);
        input.is_error = true;
        let output = model_result(&input);
        assert!(!output.success);
        assert_eq!(output.images.len(), 2);
        assert!(output.content.contains("NEXT_ACTION: ask_user"));
        assert!(output.content.contains("exact-digest"));
        assert!(!output.content.contains("must-not-reach-model"));
        assert!(!output.content.contains(&png_data(1, 1)));
    }

    #[test]
    fn structured_only_result_is_not_no_output_or_duplicated_json() {
        let input = result(vec![]);
        assert!(model_result(&input).content.contains("exact-digest"));
        let mut repeated = input.clone();
        repeated.content = vec![json!({
            "type": "text", "text": input.structured_content.unwrap().to_string()
        })];
        assert_eq!(
            model_result(&repeated)
                .content
                .matches("exact-digest")
                .count(),
            1
        );
    }

    #[test]
    fn audience_and_resource_boundaries_are_preserved() {
        let output = model_result(&result(vec![
            json!({"type": "text", "text": "user-only", "annotations": {"audience": ["user"]}}),
            json!({"type": "image", "mimeType": "image/png", "data": "YQ==",
                   "annotations": {"audience": ["user"]}}),
            json!({"type": "resource_link", "uri": "https://example.org/a", "_meta": {"secret": "hidden"}}),
            json!({"type": "resource", "resource": {"uri": "test://code", "text": "x = 1", "_meta": {"secret": "hidden"}}}),
            json!({"type": "audio", "data": "do-not-dump-base64"}),
        ]));
        assert!(output.images.is_empty());
        assert!(!output.content.contains("user-only"));
        assert!(!output.content.contains("hidden"));
        assert!(!output.content.contains("do-not-dump-base64"));
        assert!(output.content.contains("https://example.org/a"));
        assert!(output.content.contains("x = 1"));
        assert!(output.content.contains("Unsupported MCP content"));
    }

    #[test]
    fn invalid_unsupported_and_oversized_images_have_explicit_omission_notices() {
        for block in [
            json!({"type": "image", "mimeType": "image/png", "data": "aGVsbG8="}),
            json!({"type": "image", "mimeType": "image/png", "data": "bad!"}),
            json!({"type": "image", "mimeType": "image/svg+xml", "data": "YQ=="}),
            json!({"type": "image", "mimeType": "image/png", "data": ""}),
            json!({"type": "image", "mimeType": "image/png", "data": "A".repeat(8 * 1024 * 1024)}),
        ] {
            let output = model_result(&result(vec![block]));
            assert!(output.images.is_empty());
            assert!(output
                .content
                .contains("no visual inspection was performed"));
        }
        let output = model_result(&result(vec![
            json!({"type": "image", "mimeType": "image/png", "data": png_data(1, 1)});
            9
        ]));
        assert_eq!(output.images.len(), MAX_IMAGES);
        assert!(output.content.contains("image-count limit exceeded"));
        let mut total = MAX_TOTAL_IMAGE_BYTES;
        assert!(model_image(
            &json!({"type": "image", "mimeType": "image/png", "data": png_data(1, 1)}),
            0,
            0,
            &mut total,
        )
        .is_err());
        assert_eq!(total, MAX_TOTAL_IMAGE_BYTES);
    }
}
