import SwiftUI

struct InspectorView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                runtimeSection
                contextSection
                queueSection
                branchSection
                extensionSection
                statusSection

                if model.selectedSession?.state.isLive == true {
                    Button("Stop Pi Runtime", role: .destructive) {
                        Task { await model.stopSelectedRuntime() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .background(.ultraThinMaterial)
    }

    private var runtimeSection: some View {
        InspectorSection(title: "Runtime", systemImage: "cpu") {
            InspectorRow(label: "Pi", value: runtimeVersion)
            InspectorRow(label: "Source", value: model.runtime.source)
            InspectorRow(label: "State", value: model.selectedSession?.state.title ?? "No task")
            InspectorRow(label: "Environment", value: model.selectedSession?.environment.title ?? "Local")
            if model.runtime.compatibility == .terminalOnly {
                Label("Native RPC unavailable", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(ApplePiPalette.terracotta)
            }
        }
    }

    private var contextSection: some View {
        InspectorSection(title: "Context", systemImage: "gauge.with.dots.needle.33percent") {
            InspectorRow(label: "Model", value: model.inspector.model)
            InspectorRow(label: "Thinking", value: model.inspector.thinkingLevel)
            if model.inspector.contextLimit > 0 {
                ProgressView(
                    value: Double(model.inspector.contextUsed),
                    total: Double(model.inspector.contextLimit)
                )
                Text("\(model.inspector.contextUsed.formatted()) of \(model.inspector.contextLimit.formatted()) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Usage will appear after Pi starts the task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            InspectorRow(label: "Input", value: model.inspector.inputTokens.formatted())
            InspectorRow(label: "Output", value: model.inspector.outputTokens.formatted())
        }
    }

    private var queueSection: some View {
        InspectorSection(title: "Queue", systemImage: "text.append") {
            InspectorRow(label: "Waiting", value: model.inspector.queuedMessages.formatted())
            InspectorRow(label: "Behavior", value: model.queueBehavior.title)
        }
    }

    @ViewBuilder
    private var branchSection: some View {
        if !model.inspector.branches.isEmpty {
            InspectorSection(title: "Session Tree", systemImage: "arrow.triangle.branch") {
                ForEach(model.inspector.branches) { branch in
                    Button {
                        Task { await model.navigate(to: branch.id) }
                    } label: {
                        HStack {
                            Image(systemName: branch.isCurrent ? "circle.inset.filled" : "circle")
                                .foregroundStyle(branch.isCurrent ? ApplePiPalette.accent : .secondary)
                            Text(branch.title).lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(branch.isCurrent)
                }
            }
        }
    }

    @ViewBuilder
    private var extensionSection: some View {
        if !model.inspector.extensions.isEmpty {
            InspectorSection(title: "Extensions", systemImage: "puzzlepiece.extension") {
                ForEach(model.inspector.extensions) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Circle()
                            .fill(item.isHealthy ? ApplePiPalette.sage : Color.red)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).lineLimit(1)
                            Text(item.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if !model.inspector.statusItems.isEmpty {
            InspectorSection(title: "Extension Status", systemImage: "list.bullet.rectangle") {
                ForEach(model.inspector.statusItems.keys.sorted(), id: \.self) { key in
                    InspectorRow(label: key, value: model.inspector.statusItems[key] ?? "")
                }
            }
        }
    }

    private var runtimeVersion: String {
        if let version = model.runtime.version { return "v\(version)" }
        return model.runtime.compatibility == .checking ? "Checking…" : "Unavailable"
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.caption)
    }
}
