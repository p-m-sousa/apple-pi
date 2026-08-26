import AppKit
import ImageIO
import Observation
import SwiftUI
import os

struct TranscriptView: View {
    let model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.isLoadingTranscript {
                    ProgressView("Loading session…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if model.transcript.isEmpty {
                    ContentUnavailableView {
                        Label("Ready for a task", systemImage: "ellipsis.message")
                    } description: {
                        SwiftUI.Text("Describe what you want Pi to do. Its replies, tool calls, and extension UI will appear here.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if model.transcriptTrimmedItemCount > 0 {
                            memoryPressureNotice
                        }

                        ForEach(model.transcript) { item in
                            TranscriptItemView(item: item)
                                .id(item.id)
                        }
                    }
                    .frame(maxWidth: 790, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityIdentifier("applepi.transcript")
            .onChange(of: model.transcript.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private var memoryPressureNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "memorychip")
                .foregroundStyle(ApplePiPalette.sage)
            VStack(alignment: .leading, spacing: 2) {
                SwiftUI.Text("Earlier transcript released")
                    .font(.subheadline.weight(.semibold))
                SwiftUI.Text("\(model.transcriptTrimmedItemCount) earlier items were released after macOS reported memory pressure. Pi's session file is unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Reload") {
                Task { await model.reloadFullTranscript() }
            }
            .controlSize(.small)
            .accessibilityLabel("Reload full transcript")
        }
        .padding(11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("applepi.transcript.memory-pressure-notice")
    }
}

private struct TranscriptItemView: View {
    let item: ApplePiTranscriptItem
    @State private var expanded: Bool

    init(item: ApplePiTranscriptItem) {
        self.item = item
        _expanded = State(initialValue: item.kind == .answer || item.kind == .error)
    }

    var body: some View {
        Group {
            if item.role == .user {
                userMessage
            } else if item.kind == .answer || item.kind == .error {
                expandedContent
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    expandedContent
                        .padding(.top, 8)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .foregroundStyle(iconColor)
                        SwiftUI.Text(item.title ?? defaultTitle)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if item.isStreaming {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                .padding(12)
                .background(ApplePiPalette.panelSoft.opacity(0.52), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }

    private var userMessage: some View {
        HStack {
            Spacer(minLength: 90)
            VStack(alignment: .leading, spacing: 10) {
                MarkdownContentView(
                    itemID: item.id,
                    source: item.content,
                    isStreaming: item.isStreaming
                )
                ForEach(item.attachments) { attachment in
                    AttachmentView(attachment: attachment)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(ApplePiPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }

    private var expandedContent: some View {
        HStack(alignment: .top, spacing: 12) {
            if item.role != .user {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 11) {
                if let title = item.title, item.kind == .error {
                    SwiftUI.Text(title).font(.headline)
                }
                MarkdownContentView(
                    itemID: item.id,
                    source: item.content,
                    isStreaming: item.isStreaming
                )
                ForEach(item.attachments) { attachment in
                    AttachmentView(attachment: attachment)
                }
                if item.isStreaming {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        SwiftUI.Text("Pi is working…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(item.kind == .error ? 12 : 0)
        .background(item.kind == .error ? Color.red.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }

    private var defaultTitle: String {
        switch item.kind {
        case .answer: "Answer"
        case .thinking: "Thinking"
        case .tool: "Tool"
        case .status: "Status"
        case .error: "Error"
        }
    }

    private var icon: String {
        switch item.kind {
        case .answer: "sparkles"
        case .thinking: "brain"
        case .tool: "wrench.and.screwdriver"
        case .status: "waveform.path.ecg"
        case .error: "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch item.kind {
        case .error: .red
        case .tool: ApplePiPalette.terracotta
        case .thinking: ApplePiPalette.accent
        case .status: ApplePiPalette.sage
        case .answer: ApplePiPalette.accent
        }
    }
}

private struct AttachmentView: View {
    let attachment: ApplePiAttachment
    @State private var localThumbnail: NSImage?
    @State private var localThumbnailFailed = false

    var body: some View {
        switch attachment.kind {
        case .image:
            image
                .frame(maxWidth: 560, maxHeight: 380)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.separator, lineWidth: 0.5)
                }
        case .file:
            Link(destination: attachment.url) {
                Label(attachment.name, systemImage: "doc")
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var image: some View {
        if attachment.url.isFileURL {
            Group {
                if let localThumbnail {
                    Image(nsImage: localThumbnail)
                        .resizable()
                        .scaledToFit()
                } else if localThumbnailFailed {
                    Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                } else {
                    ProgressView().frame(width: 80, height: 80)
                }
            }
            .task(id: attachment.url) {
                localThumbnail = nil
                localThumbnailFailed = false
                guard let thumbnail = await TranscriptThumbnailCache.shared.thumbnail(for: attachment.url),
                      !Task.isCancelled else {
                    if !Task.isCancelled { localThumbnailFailed = true }
                    return
                }
                localThumbnail = NSImage(cgImage: thumbnail.image, size: .zero)
            }
        } else {
            AsyncImage(url: attachment.url) { phase in
                switch phase {
                case let .success(image): image.resizable().scaledToFit()
                case .failure: Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                case .empty: ProgressView().frame(width: 80, height: 80)
                @unknown default: EmptyView()
                }
            }
        }
    }
}

private struct MarkdownContentView: View {
    private struct RequestIdentity: Equatable {
        let source: String
        let isStreaming: Bool
    }

    private let itemID: String
    private let source: String
    private let isStreaming: Bool
    @State private var renderer = MarkdownItemRenderController()

    init(itemID: String, source: String, isStreaming: Bool) {
        self.itemID = itemID
        self.source = source
        self.isStreaming = isStreaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let renderedPlan = renderer.renderedPlan, renderedPlan.source == source {
                ForEach(Array(renderedPlan.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case let .prose(value):
                        SwiftUI.Text(value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case let .code(language, source):
                        CodeBlockView(language: language, source: source)
                    case let .table(headers, rows):
                        MarkdownTableView(headers: headers, rows: rows)
                    }
                }
            } else {
                // Keep streaming text visible while its formatted plan is rendered off-main.
                SwiftUI.Text(source)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.body)
        .onAppear {
            renderer.request(itemID: itemID, source: source, isFinal: !isStreaming)
        }
        .onChange(of: RequestIdentity(source: source, isStreaming: isStreaming)) { _, request in
            renderer.request(itemID: itemID, source: request.source, isFinal: !request.isStreaming)
        }
        .onDisappear { renderer.cancel() }
    }
}

@MainActor
@Observable
private final class MarkdownItemRenderController {
    private struct Request {
        let itemID: String
        let source: String
        let isFinal: Bool
    }

    private(set) var renderedPlan: RenderedMarkdownPlan?
    @ObservationIgnored private var desiredSource = ""
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var dirtyFollowUp: Request?

    func request(itemID: String, source: String, isFinal: Bool) {
        desiredSource = source
        let request = Request(itemID: itemID, source: source, isFinal: isFinal)
        guard inFlight == nil else {
            // Streaming bursts retain only the newest request. Completion is
            // represented explicitly so the exact final source takes the next slot.
            dirtyFollowUp = request
            return
        }
        start(request)
    }

    func cancel() {
        desiredSource = ""
        dirtyFollowUp = nil
        inFlight?.cancel()
        inFlight = nil
    }

    private func start(_ request: Request) {
        inFlight = Task { [weak self] in
            let plan: RenderedMarkdownPlan?
            do {
                plan = try await MarkdownRenderActor.shared.render(request.source)
            } catch {
                plan = nil
            }
            guard let self else { return }
            self.finish(request, plan: plan)
        }
    }

    private func finish(_ request: Request, plan: RenderedMarkdownPlan?) {
        inFlight = nil
        if desiredSource == request.source, let plan {
            renderedPlan = plan
        }

        guard let followUp = dirtyFollowUp else { return }
        dirtyFollowUp = nil
        // If completion only toggled streaming state after the exact source was
        // rendered, that plan is already the immediate final render.
        if followUp.source == request.source, renderedPlan?.source == followUp.source {
            return
        }
        start(followUp)
    }
}

private struct RenderedMarkdownPlan: Sendable {
    let source: String
    let blocks: [RenderedMarkdownBlock]
}

private enum RenderedMarkdownBlock: Sendable {
    case prose(AttributedString)
    case code(language: String?, source: String)
    case table(headers: [String], rows: [[String]])
}

private actor MarkdownRenderActor {
    static let shared = MarkdownRenderActor()

    private final class Box: NSObject {
        let plan: RenderedMarkdownPlan
        init(_ plan: RenderedMarkdownPlan) { self.plan = plan }
    }

    private let signposter = OSSignposter(
        subsystem: "com.paulsousa.ApplePi",
        category: .pointsOfInterest
    )
    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 96
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()
    private var activeRenderCount = 0
    private var maximumActiveRenderCount = 0
    private var completedRenderCount = 0

    func render(_ source: String) throws -> RenderedMarkdownPlan {
        try Task.checkCancellation()
        let key = source as NSString
        if let cached = cache.object(forKey: key) {
            return cached.plan
        }

        activeRenderCount += 1
        maximumActiveRenderCount = max(maximumActiveRenderCount, activeRenderCount)
        defer {
            activeRenderCount -= 1
            completedRenderCount += 1
        }
        let interval = signposter.beginInterval("MarkdownRender")
        defer { signposter.endInterval("MarkdownRender", interval) }
        let blocks = MarkdownBlockParser.parse(source).map { block -> RenderedMarkdownBlock in
            switch block {
            case let .prose(prose):
                let value = (try? AttributedString(
                    markdown: prose,
                    options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
                )) ?? AttributedString(prose)
                return .prose(value)
            case let .code(language, source):
                return .code(language: language, source: source)
            case let .table(headers, rows):
                return .table(headers: headers, rows: rows)
            }
        }
        try Task.checkCancellation()
        let plan = RenderedMarkdownPlan(source: source, blocks: blocks)
        cache.setObject(Box(plan), forKey: key, cost: max(1, source.utf8.count * 2))
        return plan
    }

    func purge() {
        cache.removeAllObjects()
    }

    func resetStatisticsForTesting() {
        cache.removeAllObjects()
        activeRenderCount = 0
        maximumActiveRenderCount = 0
        completedRenderCount = 0
    }

    func statisticsForTesting() -> (maximumActive: Int, completed: Int) {
        (maximumActiveRenderCount, completedRenderCount)
    }
}

private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}

private actor TranscriptThumbnailCache {
    static let shared = TranscriptThumbnailCache()

    private final class Box: NSObject {
        let image: SendableCGImage
        init(_ image: SendableCGImage) { self.image = image }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()
    private var decodeCount = 0

    func thumbnail(for url: URL) -> SendableCGImage? {
        guard url.isFileURL else { return nil }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.standardizedFileURL.path)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? -1)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1_120
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 760
        let scale = min(1, min(1_120 / max(1, width), 760 / max(1, height)))
        let maximumPixelSize = max(1, Int(ceil(max(width, height) * scale)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        decodeCount += 1
        let sendable = SendableCGImage(image: image)
        let cost = max(1, min(Int.max / 2, image.bytesPerRow * image.height))
        cache.setObject(Box(sendable), forKey: key, cost: cost)
        return sendable
    }

    func purge() {
        cache.removeAllObjects()
    }

    func resetStatisticsForTesting() {
        cache.removeAllObjects()
        decodeCount = 0
    }

    func decodeCountForTesting() -> Int {
        decodeCount
    }
}

enum TranscriptResourceCaches {
    static func purgeForMemoryPressure() {
        Task {
            await MarkdownRenderActor.shared.purge()
            await TranscriptThumbnailCache.shared.purge()
        }
    }
}

enum TranscriptRenderingTestSupport {
    enum Block: Sendable, Equatable {
        case prose(String)
        case code(language: String?, source: String)
        case table(headers: [String], rows: [[String]])
    }

    static func render(_ source: String) async throws -> [Block] {
        let plan = try await MarkdownRenderActor.shared.render(source)
        return plan.blocks.map { block in
            switch block {
            case let .prose(value): .prose(String(value.characters))
            case let .code(language, source): .code(language: language, source: source)
            case let .table(headers, rows): .table(headers: headers, rows: rows)
            }
        }
    }

    static func resetMarkdownStatistics() async {
        await MarkdownRenderActor.shared.resetStatisticsForTesting()
    }

    static func markdownStatistics() async -> (maximumActive: Int, completed: Int) {
        await MarkdownRenderActor.shared.statisticsForTesting()
    }

    static func thumbnailPixelSize(for url: URL) async -> (width: Int, height: Int)? {
        guard let thumbnail = await TranscriptThumbnailCache.shared.thumbnail(for: url) else { return nil }
        return (thumbnail.image.width, thumbnail.image.height)
    }

    static func resetThumbnailStatistics() async {
        await TranscriptThumbnailCache.shared.resetStatisticsForTesting()
    }

    static func thumbnailDecodeCount() async -> Int {
        await TranscriptThumbnailCache.shared.decodeCountForTesting()
    }

    static func purge() async {
        await MarkdownRenderActor.shared.purge()
        await TranscriptThumbnailCache.shared.purge()
    }
}

private enum MarkdownRenderBlock {
    case prose(String)
    case code(language: String?, source: String)
    case table(headers: [String], rows: [[String]])
}

private enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownRenderBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownRenderBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var insideFence = false
        var index = 0

        func flushProse() {
            guard !prose.isEmpty else { return }
            blocks.append(.prose(prose.joined(separator: "\n")))
            prose.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("```") {
                if insideFence {
                    blocks.append(.code(language: language, source: code.joined(separator: "\n")))
                    code.removeAll(keepingCapacity: true)
                    language = nil
                } else {
                    flushProse()
                    let rawLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    language = rawLanguage.isEmpty ? nil : rawLanguage
                }
                insideFence.toggle()
                index += 1
                continue
            }

            if insideFence {
                code.append(line)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               looksLikeTableRow(line),
               looksLikeSeparator(lines[index + 1]) {
                flushProse()
                let headers = tableCells(line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, looksLikeTableRow(lines[index]) {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            prose.append(line)
            index += 1
        }

        if insideFence {
            blocks.append(.code(language: language, source: code.joined(separator: "\n")))
        }
        flushProse()
        return blocks
    }

    private static func looksLikeTableRow(_ line: String) -> Bool {
        line.filter { $0 == "|" }.count >= 2
    }

    private static func looksLikeSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: CharacterSet(charactersIn: " :-"))
            return trimmed.isEmpty && cell.contains("-")
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let source: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SwiftUI.Text(language ?? "Code")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(ApplePiPalette.deep.opacity(0.12))

            ScrollView(.horizontal) {
                SwiftUI.Text(source)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(ApplePiPalette.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        }
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        SwiftUI.Text(header).fontWeight(.semibold)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(headers.indices, id: \.self) { index in
                            SwiftUI.Text(index < row.count ? row[index] : "")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(11)
        }
        .background(ApplePiPalette.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
    }
}
