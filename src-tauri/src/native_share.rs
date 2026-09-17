//! Native share HTML uses the WebView's standalone export stylesheet.
use pulldown_cmark::{html::push_html, Event, Options, Parser, Tag};
use wisp_dto::native_conversations::ShareRow;

fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}
fn safe_url(url: &str) -> bool {
    let url = url.trim().to_ascii_lowercase();
    url.starts_with("https://") || url.starts_with("http://") || url.starts_with("mailto:") || url.starts_with('#')
}
fn markdown(text: &str) -> String {
    let parser = Parser::new_ext(text, Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS).map(|event| match event {
        Event::Html(text) | Event::InlineHtml(text) => Event::Text(text),
        Event::Start(Tag::Link { link_type, dest_url, title, id }) => Event::Start(Tag::Link {
            link_type, dest_url: if safe_url(&dest_url) { dest_url } else { "#".into() }, title, id,
        }),
        Event::Start(Tag::Image { link_type, dest_url, title, id }) => Event::Start(Tag::Image {
            link_type, dest_url: if safe_url(&dest_url) { dest_url } else { "#".into() }, title, id,
        }),
        other => other,
    });
    let mut output = String::new();
    push_html(&mut output, parser);
    output
}
pub(crate) fn html(rows: &[ShareRow], dark: bool) -> Result<String, String> {
    if rows.is_empty() || rows.iter().map(|row| row.text.len()).sum::<usize>() > 16 * 1024 * 1024 {
        return Err("Select messages within the 16 MiB share limit".into());
    }
    let mut output = String::from("<!doctype html><html lang=\"zh\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Wisp Science</title><style>");
    output.push_str(include_str!("../../ui/src/styles/share-export.css"));
    if dark { output.push_str(":root{color-scheme:dark;--bg-app:#191817;--bg-elev:#242220;--bg-sunken:#201e1c;--text:#e9e6df;--text-muted:#b2aea3;--text-faint:#979287;--border:#38342f}"); }
    output.push_str("</style></head><body><main class=\"share-page\"><header class=\"share-head\"><h1>Wisp Science</h1></header><div class=\"thread\">");
    for row in rows {
        let (class, label, body) = match row.role.as_str() {
            "user" => ("user", "你", format!("<div class=\"user-bubble\"><div class=\"body\">{}</div></div>", escape(&row.text))),
            "assistant" => ("assistant", "Wisp Science", format!("<div class=\"assistant-wrap\"><div class=\"body md\">{}</div></div>", markdown(&row.text))),
            "reasoning" => ("reasoning", "思考", format!("<div class=\"body\">{}</div>", escape(&row.text))),
            _ => return Err("Unsupported share role".into()),
        };
        output.push_str(&format!("<article class=\"msg {class}\"><div class=\"role\">{label}</div>{body}</article>"));
    }
    output.push_str("</div><footer class=\"share-foot\">Shared from Wisp Science</footer></main></body></html>");
    Ok(output)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn renders_markdown_and_neutralizes_active_content() {
        let output = html(&[ShareRow { role: "assistant".into(), text: "**result** <script>alert(1)</script> [bad](javascript:alert)".into() }], false).unwrap();
        assert!(output.contains("<strong>result</strong>"));
        assert!(!output.contains("<script>"));
        assert!(!output.contains("href=\"javascript:"));
        assert!(output.contains("share-page"));
    }
    #[test]
    fn rejects_empty_and_tool_rows() {
        assert!(html(&[], false).is_err());
        assert!(html(&[ShareRow { role: "tool".into(), text: "secret".into() }], false).is_err());
    }
}
