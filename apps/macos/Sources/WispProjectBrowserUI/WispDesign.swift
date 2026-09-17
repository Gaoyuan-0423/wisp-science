import AppKit
import SwiftUI

/// Generated resources come from base.css, compose_icon(), and the WebView wordmarks.
enum WispDesign {
    // SwiftPM's generated lookup differs across Swift releases. Packaged apps
    // always put resources in Contents/Resources; `swift test/run` uses module.
    private static let resources: Bundle = {
        if let url = Bundle.main.url(forResource: "WispSciencePreview_WispProjectBrowserUI", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
    static let palettes: [String: [String: String]] = {
        let url = resources.url(forResource: "palette", withExtension: "json")!
        return try! JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url))
    }()

    static func color(_ token: String, _ scheme: ColorScheme) -> Color {
        let value = palettes[scheme == .dark ? "dark" : "light"]![token]!
        if value.hasPrefix("#") {
            let rgb = UInt32(value.dropFirst(), radix: 16)!
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                         green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
        }
        // The exported --border token uses rgba in both WebView themes.
        let components = value.dropFirst(5).dropLast().split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces))!
        }
        return Color(.sRGB, red: components[0] / 255, green: components[1] / 255,
                     blue: components[2] / 255, opacity: components[3])
    }

    static func image(_ name: String) -> NSImage {
        NSImage(contentsOf: resources.url(forResource: name, withExtension: "svg")!)!
    }
}

struct WispIcon: View {
    let name: String
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: WispDesign.image("icon-\(name)"))
            .renderingMode(.template).resizable().frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct WispButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    var primary = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(primary ? Color.white : WispDesign.color("text", scheme))
            .padding(.horizontal, 12).frame(height: compact ? 30 : 38)
            .background(compact && !primary ? Color.clear : WispDesign.color(primary ? "clay" : "bg-elev", scheme), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(compact ? Color.clear : WispDesign.color("border", scheme)))
            .opacity(!enabled ? 0.45 : (configuration.isPressed ? 0.7 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Preserve the WebView's action positions without assigning unrelated behavior
/// to controls whose native service is not connected yet.
struct WispUnavailableAction: View {
    let title: String
    var icon: String? = nil
    var iconOnly = false
    var primary = false
    var expanded = false

    var body: some View {
        Button {} label: {
            HStack(spacing: 8) {
                if let icon { WispIcon(name: icon, size: 16) }
                if !iconOnly { Text(title) }
                if expanded { Spacer(minLength: 0) }
            }
        }
        .buttonStyle(WispButtonStyle(primary: primary, compact: expanded)).disabled(true)
        .help("\(title) · 原生预览尚未接入")
        .accessibilityLabel("\(title)（尚未接入）")
    }
}
