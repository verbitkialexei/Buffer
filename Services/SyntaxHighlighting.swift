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
        // Build the TextKit stack explicitly. A bare NSTextView() does not lay out reliably
        // when embedded in SwiftUI (it can collapse to zero height), so the text container and
        // layout manager are wired up by hand with width tracking enabled.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: NSRect.zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize.zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        // Hug content vertically so SwiftUI gives it exactly the height the text needs.
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        textView.textStorage?.setAttributedString(attributedText)
        textView.invalidateIntrinsicContentSize()
    }

    /// Report the laid-out height for the available width so the preview shows the full snippet
    /// instead of collapsing. Width comes from the SwiftUI-proposed size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width: CGFloat = proposal.width ?? nsView.bounds.width
        guard width > 0, let layoutManager = nsView.layoutManager, let container = nsView.textContainer else {
            return nil
        }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }
}
