import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @Bindable var model: AppModel
    @State private var showProjectImporter = false
    @State private var notificationStatus = "Not requested"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ApplePiMark().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up ApplePi")
                        .font(.title2.weight(.semibold))
                    Text("A lightweight native interface for your existing Pi installation.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)

            Divider()

            Form {
                Section("Pi Runtime") {
                    LabeledContent("Detected", value: runtimeDescription)
                    Text(model.runtime.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Model Provider") {
                    LabeledContent("Readiness", value: providerReadiness)
                        .accessibilityIdentifier("applepi.onboarding.provider-readiness")
                    LabeledContent("Credentials", value: "Managed exclusively by Pi")
                    Text("Provider login and credentials are configured and stored by Pi. ApplePi does not read, copy, or validate those secrets, so readiness is confirmed in Pi's own interface.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Configure Providers in Pi…") {
                        Task { _ = await model.requestTerminal(.configuration) }
                    }
                }

                Section("Projects") {
                    LabeledContent(
                        "Saved projects",
                        value: model.projects.isEmpty ? "None yet" : "\(model.projects.count)"
                    )
                    Text("Projects group related tasks around a working folder. You can always start a standalone task from Tasks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(model.projects.isEmpty ? "Add Project Folder…" : "Add Another Project…") {
                        showProjectImporter = true
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $model.appearance) {
                        ForEach(ApplePiAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Notifications") {
                    LabeledContent("Background task updates", value: notificationStatus)
                    Button("Allow Notifications") {
                        Task {
                            notificationStatus = await model.requestNotificationPermission() ? "Allowed" : "Not allowed"
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 430)

            Divider()

            HStack {
                Text("ApplePi does not store provider credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Continue") { model.finishSetup() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("applepi.onboarding.continue")
            }
            .padding(18)
        }
        .frame(width: 620, height: 660)
        .fileImporter(
            isPresented: $showProjectImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let directory = urls.first {
                Task { await model.addProject(workingDirectory: directory) }
            }
        }
        .task { await model.refresh(initial: true) }
    }

    private var runtimeDescription: String {
        let version = model.runtime.version.map { "v\($0)" } ?? "Unknown version"
        return switch model.runtime.compatibility {
        case .checking: "Checking…"
        case .compatible: version
        case .terminalOnly: "\(version) · terminal only"
        case .unavailable: "Bundled fallback will be used"
        }
    }

    private var providerReadiness: String {
        switch model.runtime.compatibility {
        case .checking:
            "Waiting for Pi runtime"
        case .compatible:
            "Not verified by ApplePi"
        case .terminalOnly:
            "Not verified · use Pi Terminal"
        case .unavailable:
            "Pi runtime required"
        }
    }
}
