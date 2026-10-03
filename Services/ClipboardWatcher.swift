import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

/// Monitors the system clipboard for changes and captures new content
class ClipboardWatcher: ObservableObject {
    @Published private(set) var isPaused = false
    
    private let store: ClipboardStore
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var lastContentHash: Int = 0
    private var ignoreNextChange = false
    
    private let pollInterval: TimeInterval = 0.5
    
    // Size thresholds for text handling
    private let inlineTextLimit = 50_000       // 50 KB — store inline
    private let previewLength = 500            // Characters kept as inline preview
    private let richTextLimit = 500_000        // 500 KB per flavour - larger payloads are dropped, plain text still captured

    // Combined-item capture budgets (section 4.3): bound attachment extraction cost and count
    private let maxEmbeddedImages = 8
    private let minEmbeddedImageEdge: CGFloat = 32   // POINTS, not pixels - filters visual noise, not resolution
    private let maxAttributedParseBytes = 10_000_000 // refuse to materialise a document larger than this
    private let maxAttachmentBytes = 5_000_000       // per attachment, measured on the PNG we would write

    static func shouldCaptureText(_ text: String, minimumLength: Int) -> Bool {
        !text.isEmpty && text.count >= minimumLength
    }
    
    init(store: ClipboardStore) {
        self.store = store
        self.lastChangeCount = NSPasteboard.general.changeCount
        
        // Listen for ignore notification (when copying from history)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIgnoreNextChange),
            name: .bufferIgnoreNextChange,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleIgnoreNextChange() {
        ignoreNextChange = true
    }
    
    func startWatching() {
        guard timer == nil else { return }
        
        timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        
        RunLoop.main.add(timer!, forMode: .common)
    }
    
    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }
    
    func pause() {
        isPaused = true
    }
    
    func resume() {
        isPaused = false
        lastChangeCount = NSPasteboard.general.changeCount
    }
    
    private func checkClipboard() {
        guard !isPaused else { return }
        
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        
        // No change detected
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount
        
        // Skip if this is a copy from our own history
        if ignoreNextChange {
            ignoreNextChange = false
            return
        }
        
        // Get current frontmost app as source
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        
        // Check for single image file from Finder BEFORE text check
        // (Finder always writes both NSFilenamesPboardType + .string, so we must intercept first)
        if let filePaths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
           filePaths.count == 1,
           let filePath = filePaths.first {
            if isImageFile(filePath) {
                // Read and process image file asynchronously to avoid blocking the poll timer
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.processImageFile(filePath, sourceApp: sourceApp)
                }
                return  // Prevent .string branch from also processing this change
            }
        }
        
        // Try to capture text first
        if let text = pasteboard.string(forType: .string),
           Self.shouldCaptureText(text, minimumLength: SettingsManager.shared.minTextLength) {
            let rich = captureRichText(from: pasteboard)   // (rtf: Data?, html: Data?, rtfd: Data?)
            let textSize = text.utf8.count

            // Use prefix hash for large text to avoid expensive full-string hashing
            let hashSource = textSize > inlineTextLimit ? String(text.prefix(10_000)) : text

            // Raw attributed flavours, read on the main thread while the pasteboard is still current.
            // Not filtered by richTextLimit - that cap governs what we STORE. These are bounded instead
            // by maxAttributedParseBytes inside extractAttachments, which is where the cost actually is.
            let rtfdFlavour = SettingsManager.shared.preserveRichText ? pasteboard.data(forType: .rtfd) : nil
            let rtfFlavour = SettingsManager.shared.preserveRichText ? pasteboard.data(forType: .rtf) : nil

            if rtfdFlavour == nil && rtfFlavour == nil {
                // Fast path, identical to 3a: no attachments possible.
                let hash = hashSource.hashValue
                if hash != lastContentHash {
                    lastContentHash = hash
                    if let item = buildTextItem(text: text, sourceApp: sourceApp, rtf: rich.rtf, html: rich.html, rtfd: rich.rtfd) {
                        store.add(item)
                    }
                }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                // 1. Parse. No disk, no network. Bounded by maxAttributedParseBytes.
                let attachments = self.extractAttachments(rtfd: rtfdFlavour, rtf: rtfFlavour)

                // 2. Hash BEFORE any disk write, mixing attachment bytes so that the same caption
                //    copied twice with different pictures is not swallowed as a duplicate.
                let hash = attachments.isEmpty
                    ? hashSource.hashValue
                    : attachments.reduce(hashSource.hashValue) { $0 ^ $1.hashValue }

                // 3. Persist attachments.
                let filenames = attachments.compactMap { self.store.saveImage($0) }

                // 4. Build. On failure, roll back the files we just wrote.
                guard let item = self.buildTextItem(text: text, sourceApp: sourceApp, rtf: rich.rtf, html: rich.html, rtfd: rich.rtfd, imageFilenames: filenames) else {
                    self.removeImageFiles(filenames)
                    return
                }

                // 5. Gate + record + add, as one unit on the main thread.
                DispatchQueue.main.async {
                    guard hash != self.lastContentHash else {
                        self.removeImageFiles(filenames)     // rejected capture must not leak
                        return
                    }
                    self.lastContentHash = hash
                    self.store.add(item)
                }
            }
            return
        }
        
        // Try to capture image
        if let imageData = getImageData(from: pasteboard) {
            let hash = imageData.hashValue
            
            // Skip consecutive duplicates
            if hash != lastContentHash {
                lastContentHash = hash
                
                // Save image to disk
                if let filename = store.saveImage(imageData) {
                    let item = ClipboardItem.image(filename: filename, sourceApp: sourceApp)
                    store.add(item)
                }
            }
        }
    }
    
    /// Read the styled flavours of the current pasteboard, honouring the user setting and the size cap.
    /// .rtfd is captured only as the resolution-2 paste-fidelity fallback (images do not survive via
    /// .rtf's inline embedding, per feature3-design.md section 4.8) - it is not parsed here.
    private func captureRichText(from pasteboard: NSPasteboard) -> (rtf: Data?, html: Data?, rtfd: Data?) {
        guard SettingsManager.shared.preserveRichText else { return (nil, nil, nil) }
        return (capped(pasteboard.data(forType: .rtf), flavour: "rtf"),
                capped(pasteboard.data(forType: .html), flavour: "html"),
                capped(pasteboard.data(forType: .rtfd), flavour: "rtfd"))
    }

    private func capped(_ data: Data?, flavour: String) -> Data? {
        guard let data = data else { return nil }
        guard data.count <= richTextLimit else {
            print("[Buffer] Dropping \(flavour) flavour: \(data.count / 1024) KB exceeds cap")
            return nil
        }
        return data
    }

    /// Build a text item, choosing inline or file-backed storage by size. Returns nil only if the
    /// large-text file could not be written (matching today's behaviour of skipping the capture).
    private func buildTextItem(text: String, sourceApp: String?,
                                rtf: Data?, html: Data?, rtfd: Data? = nil,
                                imageFilenames: [String] = []) -> ClipboardItem? {
        let textSize = text.utf8.count
        if textSize <= inlineTextLimit {
            var item = ClipboardItem.text(text, sourceApp: sourceApp, rtfData: rtf, htmlData: html, rtfdData: rtfd)
            item.imageFilenames = imageFilenames
            return item
        }
        guard let filename = store.saveText(text) else { return nil }
        print("[Buffer] Large text (\(textSize / 1024) KB) saved to file: \(filename)")
        var item = ClipboardItem.largeText(preview: String(text.prefix(previewLength)),
                                            filename: filename, sourceApp: sourceApp,
                                            rtfData: rtf, htmlData: html, rtfdData: rtfd)
        item.imageFilenames = imageFilenames
        return item
    }

    /// Extract image attachments from an attributed pasteboard flavour. Never performs network I/O.
    private func extractAttachments(rtfd: Data?, rtf: Data?) -> [Data] {
        // Pick the preferred flavour that is small enough to parse. A flavour over the cap is not
        // a reason to fall back to a larger one, so both are tested against the same budget.
        let source: (data: Data, isRTFD: Bool)?
        if let rtfd = rtfd, rtfd.count <= maxAttributedParseBytes { source = (rtfd, true) }
        else if let rtf = rtf, rtf.count <= maxAttributedParseBytes { source = (rtf, false) }
        else { source = nil }

        guard let source = source else {
            if let oversized = rtfd ?? rtf {
                print("[Buffer] Skipping attachment extraction: attributed flavour is \(oversized.count / 1024) KB")
            }
            return []
        }

        let attributed = source.isRTFD
            ? NSAttributedString(rtfd: source.data, documentAttributes: nil)
            : NSAttributedString(rtf: source.data, documentAttributes: nil)
        guard let doc = attributed else { return [] }

        var out: [Data] = []
        doc.enumerateAttribute(.attachment, in: NSRange(location: 0, length: doc.length)) { value, _, stop in
            guard out.count < maxEmbeddedImages else { stop.pointee = true; return }
            guard let attachment = value as? NSTextAttachment else { return }
            let raw = attachment.fileWrapper?.regularFileContents
                ?? attachment.image?.tiffRepresentation
            guard let data = raw,
                  let image = NSImage(data: data),
                  image.size.width >= minEmbeddedImageEdge, image.size.height >= minEmbeddedImageEdge,
                  let png = Self.pngData(from: data),
                  png.count <= maxAttachmentBytes else { return }
            out.append(png)
        }
        if out.count >= maxEmbeddedImages {
            print("[Buffer] Capping embedded images at \(maxEmbeddedImages)")
        }
        return out
    }

    /// Shared PNG re-encode used by both pasteboard-image capture and attachment extraction.
    private static func pngData(from data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData
    }

    /// Remove image files written during a capture that did not complete. Not for live items -
    /// those go through ClipboardStore.deleteAssociatedFiles(for:).
    private func removeImageFiles(_ filenames: [String]) {
        guard !filenames.isEmpty else { return }
        store.removeImageFiles(filenames)
    }

    private func getImageData(from pasteboard: NSPasteboard) -> Data? {
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        
        for type in imageTypes {
            // Preserves today's raw-data fallback (`?? data`): without it, pasteboard images
            // that NSImage cannot round-trip stop being captured at all.
            if let data = pasteboard.data(forType: type) {
                return Self.pngData(from: data) ?? data
            }
        }
        
        return nil
    }
    
    /// Check if a file path points to an image by examining its UTType
    private func isImageFile(_ filePath: String) -> Bool {
        let fileExtension = (filePath as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return false }
        
        if let utType = UTType(filenameExtension: fileExtension) {
            return utType.conforms(to: .image)
        }
        return false
    }
    
    /// Read image file from disk, convert to PNG, and store as image item
    private func processImageFile(_ filePath: String, sourceApp: String?) {
        do {
            // Read file bytes
            let fileURL = URL(fileURLWithPath: filePath)
            let fileData = try Data(contentsOf: fileURL)
            
            // Convert to PNG using the same pattern as pasteboard image handling
            guard let pngData = Self.pngData(from: fileData) else {
                print("[Buffer] Failed to convert image file: \(filePath)")
                return
            }
            
            // Check for duplicate using hash
            let hash = pngData.hashValue
            guard hash != lastContentHash else {
                // print("[Buffer] Duplicate image file detected: \(filePath)")
                return
            }
            
            // Save image to disk and add to store
            if let filename = store.saveImage(pngData) {
                let item = ClipboardItem.image(filename: filename, sourceApp: sourceApp)
                DispatchQueue.main.async { [weak self] in
                    self?.lastContentHash = hash
                    self?.store.add(item)
                }
            }
        } catch {
            print("[Buffer] Error processing image file: \(filePath) - \(error)")
        }
    }
}
