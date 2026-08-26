import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            runtime
                .tabItem { Label("Pi Runtime", systemImage: "terminal") }
            privacy
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            advanced
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560, height: 410)
        .scenePadding()
    }

    private var general: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $model.appearance) {
                    ForEach(ApplePiAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Task Runtimes") {
                Stepper("Maximum generating turns: \(model.maximumConcurrentTurns)", value: $model.maximumConcurrentTurns, in: 1...8)
                Stepper("Idle runtime grace: \(model.idleRuntimeGraceSeconds) seconds", value: $model.idleRuntimeGraceSeconds, in: 0...120, step: 5)
                Text("Tasks above the limit queue visibly. Extension-backed runtimes remain alive to preserve extension state until stopped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var runtime: some View {
        Form {
            Section("Resolved Pi") {
                LabeledContent("Status", value: runtimeStatus)
                if let version = model.runtime.version {
                    LabeledContent("Version", value: version)
                }
                LabeledContent("Source", value: model.runtime.source)
                Text(model.runtime.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Executable Override") {
                TextField("Path to pi", text: $model.savedExecutablePath)
                    .font(.body.monospaced())
                Text("Resolution order: saved executable, login-shell PATH, then common install locations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if model.runtime.compatibility == .unavailable {
                        Link("Install Pi…", destination: Self.piInstallationURL)
                    }
                    Button("Retry Detection") {
                        Task { await model.refresh() }
                    }
                    .disabled(model.isRefreshing)
                }
            }

            Button("Open Pi Configuration…") {
                Task { _ = await model.requestTerminal(.configuration) }
            }
            .disabled(model.runtime.executableURL == nil)
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Section("ApplePi") {
                Label("No ApplePi telemetry or analytics", systemImage: "checkmark.shield")
                Text("Diagnostics stay local unless you explicitly export a redacted support bundle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Pi") {
                Text("Pi owns provider requests, credential storage, tools, project trust, and its own telemetry setting. ApplePi does not override PI_TELEMETRY.")
                    .font(.callout)
                Text("The Discover tab connects only to pi.dev and uses a nonpersistent web data store.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var advanced: some View {
        Form {
            Section("Compatibility") {
                Toggle("Allow compatible out-of-range runtimes", isOn: $model.advancedRuntimeOverride)
                Text("ApplePi normally accepts Pi >= 0.84.2 and < 0.85.0 after capability probes. An override still requires the native bridge probe to succeed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Setup") {
                Button("Show First-Run Setup Again") { model.resetSetup() }
            }
        }
        .formStyle(.grouped)
    }

    private var runtimeStatus: String {
        switch model.runtime.compatibility {
        case .checking: "Checking"
        case .compatible: "Compatible"
        case .terminalOnly: "Terminal only"
        case .unavailable: "Unavailable"
        }
    }

    private static let piInstallationURL = URL(string: "https://pi.dev/docs/latest/quickstart")!
}
