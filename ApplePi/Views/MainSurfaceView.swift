import SwiftUI

struct MainSurfaceView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var searchPresented = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model, searchPresented: $searchPresented)
                .navigationSplitViewColumnWidth(min: 220, ideal: 272, max: 350)
        } detail: {
            detail
                .inspector(isPresented: taskInspectorPresented) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 235, ideal: 278, max: 360)
                        .accessibilityIdentifier("applepi.inspector")
                }
        }
        .navigationTitle(windowTitle)
        .toolbar { toolbar }
        .overlay {
            if searchPresented {
                SearchPaletteView(model: model, isPresented: $searchPresented)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: searchPresented)
        .sheet(isPresented: $model.showSetup) {
            SetupView(model: model)
                .interactiveDismissDisabled()
        }
        .sheet(item: $model.extensionPrompt) { prompt in
            ExtensionPromptView(model: model, prompt: prompt)
        }
        .sheet(isPresented: $model.projectImporterPresented) {
            CreateProjectSheet(model: model)
        }
        .alert("ApplePi", isPresented: alertPresented) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onChange(of: model.selection) { previousDestination, destination in
            Task {
                await model.activate(destination, departingFrom: previousDestination)
            }
        }
        .onChange(of: model.pendingTerminal) { _, request in
            guard let request else { return }
            openWindow(value: request.id)
            model.pendingTerminal = nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .home:
            WelcomeView(model: model)
        case .extensions:
            ExtensionsView(model: model)
                .accessibilityIdentifier("applepi.extensions")
        case let .project(id):
            if let project = model.projects.first(where: { $0.id == id }) {
                ProjectDetailView(model: model, project: project)
            } else {
                WelcomeView(model: model)
            }
        case .session:
            TaskDetailView(model: model)
        }
    }

    private var windowTitle: String {
        switch model.selection {
        case .home: ""
        case .extensions: "Extensions"
        case .project: model.selectedProject?.name ?? "Project"
        case .session: model.selectedSession?.title ?? "Task"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh Pi sessions and resources")

            if let session = model.selectedSession {
                Button {
                    Task { _ = await model.requestTerminal(.session, sessionID: session.id) }
                } label: {
                    Label("Open in Pi Terminal", systemImage: "terminal")
                }
                .help("Open this session in Pi's full terminal interface")
            }

            if let project = model.selectedProject {
                Button {
                    Task { await model.createTask(in: project) }
                } label: {
                    Label("New Task in Project", systemImage: "plus.bubble")
                }
                .help("Start a new task in \(project.name)")
            }

            if model.selectedSession != nil {
                Button {
                    model.inspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(model.inspectorPresented ? "Hide Inspector" : "Show Inspector")
            }
        }
    }

    private var taskInspectorPresented: Binding<Bool> {
        Binding(
            get: { model.selectedSession != nil && model.inspectorPresented },
            set: { model.inspectorPresented = $0 }
        )
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )
    }
}

private struct CreateProjectSheet: View {
    let model: AppModel

    var body: some View {
        ProjectEditorSheet(model: model, mode: .create)
    }
}

private struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 7) {
                Text("What are we building?")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Start a standalone task, or add a project to keep related Pi tasks together.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            NewTaskButton(identifier: "applepi.welcome-new-task") {
                Task { await model.createTask() }
            }

            HStack(spacing: 8) {
                ApplePiStatusDot(state: runtimeState)
                Text(model.runtime.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ApplePiPalette.canvas.opacity(0.32))
    }

    private var runtimeState: ApplePiTaskState {
        switch model.runtime.compatibility {
        case .checking: .starting
        case .compatible: .ready
        case .terminalOnly: .awaitingInput
        case .unavailable: .failed
        }
    }
}

private struct ProjectDetailView: View {
    let model: AppModel
    let project: ApplePiProject

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "folder")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 7) {
                Text(project.name)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(project.workingDirectory.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }

            NewTaskButton(identifier: "applepi.project-detail-new-task") {
                Task { await model.createTask(in: project) }
            }

            Text(taskSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ApplePiPalette.canvas.opacity(0.32))
    }

    private var taskSummary: String {
        let count = model.sessions.filter { !$0.isArchived && $0.projectID == project.id }.count
        return count == 1 ? "1 task" : "\(count) tasks"
    }
}

private struct NewTaskButton: View {
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("New Task", systemImage: "square.and.pencil")
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .focusEffectDisabled()
        .accessibilityIdentifier(identifier)
    }
}

private struct TaskDetailView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ComposerView(model: model)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
        }
        .background(ApplePiPalette.canvas.opacity(0.26))
    }
}

private struct ExtensionPromptView: View {
    let model: AppModel
    let prompt: ApplePiExtensionPrompt
    @State private var value: String
    @State private var selection: String?

    init(model: AppModel, prompt: ApplePiExtensionPrompt) {
        self.model = model
        self.prompt = prompt
        _value = State(initialValue: prompt.defaultValue)
        if case let .select(options) = prompt.kind {
            _selection = State(initialValue: options.first)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    promptHeader
                    promptControl
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    Task { await model.respondToExtensionPrompt(value: nil, accepted: false) }
                }
                .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    let response = selection ?? value
                    Task { await model.respondToExtensionPrompt(value: response, accepted: true) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.bar)
        }
        .frame(
            minWidth: 560,
            idealWidth: 560,
            maxWidth: 560,
            minHeight: 300,
            idealHeight: 480,
            maxHeight: 680
        )
    }

    private var promptHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pi needs your input", systemImage: "questionmark.bubble")
                .font(.headline)
                .foregroundStyle(ApplePiPalette.accent)

            Text(prompt.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            if let message = prompt.message, !message.isEmpty {
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var promptControl: some View {
        switch prompt.kind {
        case let .select(options):
            LazyVStack(spacing: 10) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, rawValue in
                    let choice = ApplePiExtensionChoice(rawValue: rawValue)
                    ExtensionChoiceButton(
                        choice: choice,
                        index: index,
                        isSelected: selection == rawValue
                    ) {
                        selection = rawValue
                    }
                }
            }
        case .confirm:
            EmptyView()
        case .input:
            TextField(prompt.placeholder ?? "Response", text: $value)
                .textFieldStyle(.roundedBorder)
        case .editor:
            TextEditor(text: $value)
                .font(.body.monospaced())
                .frame(minHeight: 150)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: ApplePiRadius.compactCard))
                .overlay {
                    RoundedRectangle(cornerRadius: ApplePiRadius.compactCard)
                        .stroke(.separator, lineWidth: 0.5)
                }
        }
    }
}

private struct ExtensionChoiceButton: View {
    let choice: ApplePiExtensionChoice
    let index: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? ApplePiPalette.accent : .secondary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(choice.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)

                        if choice.isRecommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(ApplePiPalette.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(ApplePiPalette.accent.opacity(0.12), in: Capsule())
                        }
                    }

                    if let detail = choice.detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? ApplePiPalette.accent.opacity(0.10) : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: ApplePiRadius.compactCard, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ApplePiRadius.compactCard, style: .continuous)
                    .stroke(
                        isSelected ? ApplePiPalette.accent : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 1.25 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.detail.map { "\(choice.title), \($0)" } ?? choice.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier("applepi.extension-choice.\(index)")
    }
}
