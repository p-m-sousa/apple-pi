import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let onSubmit: () -> Void
    let onImagesPasted: ([ApplePiPastedImage]) -> Void

    private let minimumHeight: CGFloat = 54
    private let maximumHeight: CGFloat = 150

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            measuredHeight: $measuredHeight,
            minimumHeight: minimumHeight,
            maximumHeight: maximumHeight,
            onSubmit: onSubmit,
            onImagesPasted: onImagesPasted
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ApplePiComposerNSTextView()
        textView.delegate = context.coordinator
        textView.submitAction = context.coordinator.submit
        textView.imagesAction = context.coordinator.imagesPasted
        textView.contentSizeAction = context.coordinator.updateMeasuredHeight
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 7)
        textView.setAccessibilityIdentifier("applepi.composer-text-view")

        scrollView.documentView = textView
        context.coordinator.updateMeasuredHeight(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ApplePiComposerNSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.measuredHeight = $measuredHeight
        context.coordinator.minimumHeight = minimumHeight
        context.coordinator.maximumHeight = maximumHeight
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onImagesPasted = onImagesPasted
        textView.submitAction = context.coordinator.submit
        textView.imagesAction = context.coordinator.imagesPasted
        textView.contentSizeAction = context.coordinator.updateMeasuredHeight
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.updateMeasuredHeight(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var measuredHeight: Binding<CGFloat>
        var minimumHeight: CGFloat
        var maximumHeight: CGFloat
        var onSubmit: () -> Void
        var onImagesPasted: ([ApplePiPastedImage]) -> Void

        init(
            text: Binding<String>,
            measuredHeight: Binding<CGFloat>,
            minimumHeight: CGFloat,
            maximumHeight: CGFloat,
            onSubmit: @escaping () -> Void,
            onImagesPasted: @escaping ([ApplePiPastedImage]) -> Void
        ) {
            self.text = text
            self.measuredHeight = measuredHeight
            self.minimumHeight = minimumHeight
            self.maximumHeight = maximumHeight
            self.onSubmit = onSubmit
            self.onImagesPasted = onImagesPasted
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            updateMeasuredHeight(textView)
        }

        func submit() { onSubmit() }
        func imagesPasted(_ images: [ApplePiPastedImage]) { onImagesPasted(images) }

        @MainActor
        func updateMeasuredHeight(_ textView: NSTextView) {
            guard let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: textContainer)
            let contentHeight = ceil(
                layoutManager.usedRect(for: textContainer).height
                    + (textView.textContainerInset.height * 2)
            )
            let height = min(max(contentHeight, minimumHeight), maximumHeight)
            guard abs(measuredHeight.wrappedValue - height) > 0.5 else { return }
            measuredHeight.wrappedValue = height
        }
    }
}

private final class ApplePiComposerNSTextView: NSTextView {
    var submitAction: (() -> Void)?
    var imagesAction: (([ApplePiPastedImage]) -> Void)?
    var contentSizeAction: ((NSTextView) -> Void)?

    override func layout() {
        super.layout()
        contentSizeAction?(self)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !hasMarkedText() {
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else {
                submitAction?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let encodedImageData = Self.encodedImageData(from: pasteboard)

        guard !fileURLs.isEmpty || encodedImageData != nil else {
            super.paste(sender)
            return
        }

        // Reading pasteboard bytes is synchronous by AppKit contract, but validation,
        // filesystem reads, full-image decoding, and transcoding all happen off-main.
        // Capture text so a malformed advertised image can still fall back to normal
        // plain-text paste without consulting the pasteboard after this event returns.
        let fallbackText = pasteboard.string(forType: .string)
        Task { [weak self] in
            let result: PastedImageProcessingResult
            do {
                result = try await PastedImageProcessor.shared.process(
                    fileURLs: fileURLs,
                    fallbackPasteboardData: encodedImageData
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                if let fallbackText {
                    insertText(fallbackText, replacementRange: selectedRange())
                }
                return
            }

            guard let self else { return }
            let pathReferences = result.nonImageFileURLs.map {
                Self.pathReference(for: $0.path)
            }
            if !pathReferences.isEmpty {
                let prefix = selectedRange().location > 0 ? " " : ""
                insertText(
                    prefix + pathReferences.joined(separator: " ") + " ",
                    replacementRange: selectedRange()
                )
            }

            let images = result.images.map {
                ApplePiPastedImage(
                    data: $0.data,
                    suggestedName: $0.suggestedName,
                    mimeType: $0.mimeType
                )
            }
            if !images.isEmpty {
                imagesAction?(images)
            } else if pathReferences.isEmpty, let fallbackText {
                insertText(fallbackText, replacementRange: selectedRange())
            }
        }
    }

    private static func pathReference(for path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "@\"\(escaped)\""
    }

    private static func encodedImageData(from pasteboard: NSPasteboard) -> Data? {
        let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        let preferredTypes: [NSPasteboard.PasteboardType] = [.png, jpeg]

        for type in preferredTypes where pasteboard.types?.contains(type) == true {
            if let data = pasteboard.data(forType: type) { return data }
        }

        for type in pasteboard.types ?? [] {
            guard !preferredTypes.contains(type),
                  let uniformType = UTType(type.rawValue),
                  uniformType.conforms(to: .image),
                  let data = pasteboard.data(forType: type) else { continue }
            return data
        }
        return nil
    }
}
