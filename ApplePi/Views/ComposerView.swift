import SwiftUI

struct ComposerView: View {
    @Bindable var model: AppModel
    @State private var suggestions: [ComposerSuggestion] = []
    @State private var editorHeight: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !suggestions.isEmpty {
                suggestionStrip
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }

            if !model.composerImages.isEmpty {
                attachmentStrip
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }

            ComposerTextView(
                text: $model.composerText,
                measuredHeight: $editorHeight,
                onSubmit: submit,
                onImagesPasted: { images in
                    Task { await model.addComposerImages(images) }
                }
            )
            .frame(height: editorHeight)
            .padding(.horizontal, 7)
            .padding(.top, 6)
            .accessibilityIdentifier("applepi.composer")

            HStack(spacing: 8) {
                if let session = model.selectedSession {
                    Label(session.environment.title, systemImage: session.environment.systemImage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(session.environment == .managedWorktree ? ApplePiPalette.accent : .secondary)
                        .help(session.environment == .managedWorktree
                            ? "This task has an isolated Git checkout."
                            : "This task works directly in its local folder.")
                        .accessibilityIdentifier("applepi.task-environment")
                }

                modelMenu
                thinkingMenu
                queueMenu

                if model.composerText.hasPrefix("!") {
                    Text(model.composerText.hasPrefix("!!") ? "Shell command · exclude from context" : "Shell command · include output")
                        .font(.caption)
                        .foregroundStyle(ApplePiPalette.terracotta)
                }

                Spacer()

                if model.selectedSession?.state == .generating {
                    Button {
                        Task { await model.abortSelectedTask() }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Abort current turn (⌘.)")
                }

                Button(action: submit) {
                    Image(systemName: model.selectedSession?.state == .generating ? "arrow.turn.up.left" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 17, height: 17)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .disabled(!model.canSend)
                .help(model.selectedSession?.state == .generating ? "Queue message" : "Send to Pi")
                .accessibilityLabel("Send")
                .accessibilityIdentifier("applepi.send")
                .arrowCursor()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.separator.opacity(0.7), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.09), radius: 12, y: 5)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .task(id: model.composerText) {
            suggestions = await ComposerSuggestion.suggestions(
                for: model.composerText,
                workingDirectory: model.selectedSession?.workingDirectory,
                commands: model.availableCommands
            )
        }
    }

    private var suggestionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions) { suggestion in
                    Button {
                        apply(suggestion)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: suggestion.icon)
                            Text(suggestion.value)
                            if let detail = suggestion.detail {
                                Text(detail).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(model.composerImages) { image in
                    HStack(spacing: 5) {
                        Image(systemName: "photo")
                        Text(image.suggestedName).lineLimit(1)
                        Button {
                            model.removeComposerImage(image)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(ApplePiPalette.accent.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private var modelMenu: some View {
        Menu {
            if model.runtimeOptions.models.isEmpty {
                Button("Load Available Models…") {
                    Task { await model.refreshRuntimeOptions() }
                }
            } else {
                ForEach(model.runtimeOptions.models) { option in
                    Button {
                        Task { await model.selectModel(option) }
                    } label: {
                        Label(
                            "\(option.displayName) — \(option.provider)",
                            systemImage: isSelected(option) ? "checkmark" : "circle"
                        )
                    }
                }

                Divider()

                Button("Refresh Models") {
                    Task { await model.refreshRuntimeOptions() }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if model.isLoadingRuntimeOptions {
                    ProgressView().controlSize(.mini)
                }
                Text(model.inspector.model)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 150)
        .controlSize(.small)
        .help("Choose the Pi model")
        .accessibilityLabel("Model: \(model.inspector.model)")
        .accessibilityIdentifier("applepi.composer.model")
        .arrowCursor()
    }

    private var thinkingMenu: some View {
        Menu {
            if model.runtimeOptions.thinkingLevels.isEmpty {
                Button("Load Thinking Levels…") {
                    Task { await model.refreshRuntimeOptions() }
                }
            } else {
                ForEach(model.runtimeOptions.thinkingLevels, id: \.self) { level in
                    Button {
                        Task { await model.selectThinkingLevel(level) }
                    } label: {
                        Label(
                            level.capitalized,
                            systemImage: isSelectedThinkingLevel(level) ? "checkmark" : "circle"
                        )
                    }
                }

                Divider()

                Button("Refresh Levels") {
                    Task { await model.refreshRuntimeOptions() }
                }
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                    Text(model.inspector.thinkingLevel)
                        .lineLimit(1)
                }
                Image(systemName: "brain")
            }
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 110)
        .controlSize(.small)
        .help("Thinking: \(model.inspector.thinkingLevel)")
        .accessibilityLabel("Thinking level: \(model.inspector.thinkingLevel)")
        .accessibilityIdentifier("applepi.composer.thinking")
        .arrowCursor()
    }

    private var queueMenu: some View {
        Menu {
            Picker("While Pi is working", selection: $model.queueBehavior) {
                ForEach(ApplePiQueueBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
        } label: {
            Image(systemName: model.queueBehavior == .steer ? "arrow.triangle.branch" : "text.append")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help(model.queueBehavior.title)
        .arrowCursor()
    }

    private func submit() {
        guard model.canSend else { return }
        Task { await model.sendComposer() }
    }

    private func apply(_ suggestion: ComposerSuggestion) {
        let text = model.composerText
        let tokenStart = text.lastIndex(where: { $0.isWhitespace }).map { text.index(after: $0) } ?? text.startIndex
        model.composerText.replaceSubrange(tokenStart..<text.endIndex, with: suggestion.value + " ")
        suggestions = []
    }

    private func isSelected(_ option: ApplePiModelOption) -> Bool {
        let current = model.inspector.model.lowercased()
        return current == option.id.lowercased()
            || current == option.displayName.lowercased()
            || current.hasSuffix("/\(option.modelID.lowercased())")
    }

    private func isSelectedThinkingLevel(_ level: String) -> Bool {
        model.inspector.thinkingLevel.caseInsensitiveCompare(level) == .orderedSame
    }
}

private struct ComposerSuggestion: Identifiable, Sendable {
    let value: String
    let detail: String?
    let icon: String
    var id: String { value }

    static func suggestions(
        for text: String,
        workingDirectory: URL?,
        commands: [ApplePiComposerCommand]
    ) async -> [ComposerSuggestion] {
        let token = text.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? text
        if token.hasPrefix("/") {
            return commands
                .filter { token == "/" || $0.name.localizedCaseInsensitiveContains(token) }
                .map { ComposerSuggestion(value: $0.name, detail: $0.detail, icon: "command") }
        }

        guard token.hasPrefix("@"), let workingDirectory else { return [] }
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return [] }
        let query = String(token.dropFirst())
        return await Task.detached(priority: .utility) {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: workingDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return urls
                .filter { query.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(query) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .prefix(8)
                .map {
                    ComposerSuggestion(
                        value: "@\($0.lastPathComponent)",
                        detail: $0.hasDirectoryPath ? "Folder" : nil,
                        icon: $0.hasDirectoryPath ? "folder" : "doc"
                    )
                }
        }.value
    }
}
