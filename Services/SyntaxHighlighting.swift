import AppKit
import Highlighter

/// Abstraction over a syntax-highlighting engine.
///
/// Views depend only on this protocol, never on HighlighterSwift directly, so the engine can
/// be swapped later (for example to a tree-sitter backend) without touching the UI layer.
protocol SyntaxHighlighting {
    /// The language names this engine can highlight, for populating a manual picker.
    func supportedLanguages() -> [String]

    /// Produce a highlighted attributed string for `code`, or nil if highlighting is not
    /// possible or not warranted (caller falls back to plain monospaced text).
    ///
    /// - Parameters:
    ///   - code: the source text.
    ///   - language: a highlight.js language name to force; nil means auto-detect.
    ///   - fontSize: point size to render at (tracks the app's zoom scale).
    ///   - dark: whether the system is in dark appearance (selects the theme).
    func highlight(_ code: String, language: String?, fontSize: CGFloat, dark: Bool) -> NSAttributedString?
}

/// HighlighterSwift-backed implementation (highlight.js under the hood).
///
/// Thread-safety: `Highlighter` wraps a JavaScriptCore context and is not safe to touch from
/// multiple threads at once, so all access is serialized through a dedicated queue. Callers are
/// expected to invoke `highlight` off the main thread (see `SyntaxHighlightCache`).
final class HighlighterSwiftEngine: SyntaxHighlighting, @unchecked Sendable {

    /// Shared instance. Safe to use across threads: all engine access is serialized through
    /// an internal queue (`@unchecked Sendable` reflects that this is hand-verified, since the
    /// wrapped Highlighter/JSContext is not itself Sendable).
    static let shared = HighlighterSwiftEngine()

    /// Above this many bytes we never highlight - highlight.js tokenizing a multi-megabyte
    /// paste would hang the UI, and the preview for such content is the chunked plain-text
    /// loader anyway. 100 KB comfortably covers any real code snippet.
    static let maxHighlightBytes = 100_000

    private let lightTheme = "atom-one-light"
    private let darkTheme = "atom-one-dark"
    private let monoFontName = "Menlo-Regular"

    private let queue = DispatchQueue(label: "com.buffer.syntax-highlight")
    private let highlighter: Highlighter?
    private var currentThemeIsDark: Bool?
    private var cachedLanguages: [String]?

    init() {
        // Failable: nil if the bundled highlight.min.js or default theme is missing.
        self.highlighter = Highlighter()
    }

    func supportedLanguages() -> [String] {
        queue.sync {
            if let cached = cachedLanguages { return cached }
            let langs = highlighter?.supportedLanguages().sorted() ?? []
            cachedLanguages = langs
            return langs
        }
    }

    func highlight(_ code: String, language: String?, fontSize: CGFloat, dark: Bool) -> NSAttributedString? {
        guard code.utf8.count <= Self.maxHighlightBytes else { return nil }

        return queue.sync {
            guard let highlighter = highlighter else { return nil }

            // Re-apply the theme only when appearance changes (setTheme reloads CSS, which is
            // not free). Font size is applied on every call since zoom can change independently.
            if currentThemeIsDark != dark {
                highlighter.setTheme(dark ? darkTheme : lightTheme)
                currentThemeIsDark = dark
            }
            let font = NSFont(name: monoFontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            highlighter.theme.setCodeFont(font)

            // Empty language string is treated as "no language" (auto-detect); nil also means auto.
            let langParam = (language?.isEmpty == false) ? language : nil
            return highlighter.highlight(code, as: langParam)
        }
    }
}

import SwiftUI

/// Read-only, selectable NSTextView host for a highlighted NSAttributedString.
///
/// SwiftUI `Text` cannot render an arbitrary NSAttributedString with per-token colors, so a
/// lightweight NSTextView is wrapped instead. It is non-editable but selectable, matching the
/// `.textSelection(.enabled)` behavior of the plain-text branch it replaces.
struct HighlightedTextView: NSViewRepresentable {
    let attributedText: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // Let the enclosing SwiftUI ScrollView handle scrolling; this view sizes to content.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        textView.textStorage?.setAttributedString(attributedText)
    }
}
