import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SidebarOrganizationMode: String, CaseIterable, Identifiable {
    case byProject
    case oneList

    var id: Self { self }

    var title: String {
        switch self {
        case .byProject: "By project"
        case .oneList: "In one list"
        }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    @Binding var searchPresented: Bool
    @AppStorage("ApplePiSidebarOrganization") private var organizationMode = SidebarOrganizationMode.byProject
    @AppStorage("ApplePiSidebarTaskSortOrder") private var taskSortOrder = ApplePiSidebarTaskSortOrder.priority
    @SceneStorage("ApplePiProjectsExpanded") private var projectsExpanded = true
    @SceneStorage("ApplePiTasksExpanded") private var tasksExpanded = true
    @State private var sessionToRename: ApplePiUISession?
    @State private var sessionRenameText = ""
    @State private var sessionToDelete: ApplePiUISession?
    @State private var projectToEdit: ApplePiProject?
    @State private var projectForWorktree: ApplePiProject?
    @State private var projectToRemove: ApplePiProject?
    @State private var expandedProjectIDs: Set<ApplePiProjectID> = []
    @State private var showArchived = false

    var body: some View {
        let projection = model.sidebarProjection(sortOrder: taskSortOrder)
        VStack(spacing: 0) {
            SidebarAppHeader(
                onHome: { model.selection = .home },
                onSearch: { searchPresented.toggle() }
            )
            .padding(.leading, SidebarChromeMetrics.appHeaderLeadingInset)
            .padding(.trailing, 8)
            .padding(.top, 8)
            .padding(.bottom, SidebarChromeMetrics.hoverSpacing)

            List(selection: listSelection) {
                Section {
                    if projectsExpanded {
                        switch organizationMode {
                        case .byProject:
                            ForEach(projection.filteredProjects) { project in
                                projectTree(project, projection: projection)
                            }

                        case .oneList:
                            ForEach(projection.allVisibleTasks) { session in
                                sessionRow(session, showsTimestamp: false)
                            }
                        }

                        if projectsSectionIsEmpty(projection) {
                            Text(projectsEmptyMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    projectsHeader
                }

                if organizationMode == .byProject {
                    Section {
                        if tasksExpanded {
                            ForEach(projection.unassignedTasks) { session in
                                sessionRow(session, showsTimestamp: false)
                            }

                            if projection.unassignedTasks.isEmpty {
                                Text(model.searchText.isEmpty ? "No tasks" : "No matching tasks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        tasksHeader
                    }
                }

                if !projection.archivedSessions.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showArchived) {
                            ForEach(projection.archivedSessions) { session in
                                sessionRow(session)
                            }
                        } label: {
                            Text("Archived (\(projection.archivedSessions.count))")
                                .sidebarHoverHighlight()
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("applepi.sidebar")

            SidebarBottomNavigation(
                isExtensionsSelected: model.selection == .extensions,
                onOpenExtensions: {
                    model.selection = .extensions
                }
            )
        }
        .onAppear {
            expandedProjectIDs.formUnion(model.projects.map(\.id))
        }
        .onChange(of: model.projects.map(\.id)) { _, projectIDs in
            expandedProjectIDs.formUnion(projectIDs)
            expandedProjectIDs.formIntersection(projectIDs)
        }
        .sheet(item: $sessionToRename) { session in
            renameSheet(
                title: "Rename Task",
                fieldLabel: "Name",
                text: $sessionRenameText,
                onCancel: { sessionToRename = nil },
                onCommit: { commitSessionRename(session) }
            )
        }
        .sheet(item: $projectToEdit) { project in
            ProjectEditorSheet(model: model, mode: .edit(project))
        }
        .sheet(item: $projectForWorktree) { project in
            PermanentWorktreeSheet(model: model, project: project)
        }
        .confirmationDialog(
            "Move this Pi session to Trash?",
            isPresented: deletePresented,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                guard let sessionToDelete else { return }
                Task { await model.mutate(sessionToDelete, .moveToTrash) }
                self.sessionToDelete = nil
            }
            Button("Cancel", role: .cancel) { sessionToDelete = nil }
        } message: {
            Text("This removes the canonical Pi JSONL session. The Trash may allow recovery.")
        }
        .confirmationDialog(
            "Remove \(projectToRemove?.name ?? "this project")?",
            isPresented: removeProjectPresented,
            titleVisibility: .visible
        ) {
            Button("Remove Project", role: .destructive) {
                guard let projectToRemove else { return }
                Task { await model.removeProject(projectToRemove) }
                self.projectToRemove = nil
            }
            Button("Cancel", role: .cancel) { projectToRemove = nil }
        } message: {
            Text("Its tasks will move to Tasks. No Pi session files or project files will be deleted.")
        }
    }

    private var listSelection: Binding<ApplePiDestination?> {
        Binding {
            switch model.selection {
            case .project, .session:
                model.selection
            case .home, .extensions:
                nil
            }
        } set: { destination in
            if let destination {
                model.selection = destination
            }
        }
    }

    private var projectsHeader: some View {
        SidebarSectionHeader(
            title: "Projects",
            isExpanded: $projectsExpanded,
            organizationMode: $organizationMode,
            taskSortOrder: $taskSortOrder,
            disclosureIdentifier: "applepi.projects-disclosure",
            menuIdentifier: "applepi.projects-menu",
            addIdentifier: "applepi.add-project",
            addTitle: "Add Project",
            addSystemImage: "plus"
        ) {
            model.projectImporterPresented = true
        }
    }

    private var tasksHeader: some View {
        SidebarSectionHeader(
            title: "Tasks",
            isExpanded: $tasksExpanded,
            organizationMode: $organizationMode,
            taskSortOrder: $taskSortOrder,
            disclosureIdentifier: "applepi.tasks-disclosure",
            menuIdentifier: "applepi.tasks-menu",
            addIdentifier: "applepi.new-task",
            addTitle: "Add Task",
            addSystemImage: "square.and.pencil"
        ) {
            Task { await model.createTask() }
        }
    }

    private func projectsSectionIsEmpty(_ projection: ApplePiSidebarProjection) -> Bool {
        switch organizationMode {
        case .byProject: projection.filteredProjects.isEmpty
        case .oneList: projection.allVisibleTasks.isEmpty
        }
    }

    private var projectsEmptyMessage: String {
        if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return organizationMode == .byProject ? "No matching projects" : "No matching tasks"
        }
        return organizationMode == .byProject ? "No projects" : "No tasks"
    }

    @ViewBuilder
    private func projectTree(_ project: ApplePiProject, projection: ApplePiSidebarProjection) -> some View {
        let projectSessions = projection.sessionsByProject[project.id] ?? []
        let activeTaskCount = projection.activeTaskCountByProject[project.id, default: 0]
        ProjectSidebarRow(
            project: project,
            taskCount: activeTaskCount,
            isExpanded: projectExpansion(project.id),
            onSelect: {
                model.selection = .project(project.id)
            },
            onTogglePin: {
                Task { await model.setProjectPinned(project, pinned: !project.isPinned) }
            },
            onEdit: {
                projectToEdit = project
            },
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([project.workingDirectory])
            },
            onCreateWorktree: {
                projectForWorktree = project
            },
            onArchiveTasks: {
                Task { await model.archiveTasks(in: project) }
            },
            onRemove: {
                projectToRemove = project
            },
            onCreateTask: {
                Task { await model.createTask(in: project) }
            }
        )
        .tag(ApplePiDestination.project(project.id))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("applepi.project-row.\(project.id.rawValue.uuidString)")

        if expandedProjectIDs.contains(project.id) {
            ForEach(projectSessions) { session in
                sessionRow(session, showsTimestamp: false)
            }
        }
    }

    private func sessionRow(_ session: ApplePiUISession, showsTimestamp: Bool = true) -> some View {
        HStack(spacing: 9) {
            Image(systemName: session.wasCreatedByCLI
                ? "terminal"
                : (session.environment == .managedWorktree ? "arrow.triangle.branch" : "bubble.left"))
                .foregroundStyle(Color.white)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                SidebarTaskTitle(
                    title: session.title,
                    isDraft: model.hasTextDraft(for: session.id) && !session.state.isExecuting,
                    isExecuting: session.state.isExecuting,
                    isFailed: session.state == .failed
                )
                if showsTimestamp {
                    Text(session.modifiedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)
        }
        .sidebarHoverHighlight()
        .tag(ApplePiDestination.session(session.id))
        .accessibilityIdentifier("applepi.session-row.\(session.id)")
        .accessibilityValue(Text(session.sessionURL == nil ? "draft" : "canonical"))
        .contextMenu {
            Button("Rename…") {
                sessionRenameText = session.title
                sessionToRename = session
            }
            Button(session.isPinned ? "Unpin" : "Pin") {
                Task { await model.mutate(session, .pin(!session.isPinned)) }
            }
            Button(session.isArchived ? "Unarchive" : "Archive") {
                Task { await model.mutate(session, .archive(!session.isArchived)) }
            }

            projectAssignmentMenu(for: session)

            Divider()

            Button("Fork from Here") { Task { await model.mutate(session, .fork) } }
            Button("Clone Session") { Task { await model.mutate(session, .clone) } }

            Menu("Export") {
                Button("HTML…") { Task { await model.mutate(session, .export(.html)) } }
                Button("Raw JSONL…") { Task { await model.mutate(session, .export(.rawJSONL)) } }
            }
            Button("Reveal in Finder") { Task { await model.mutate(session, .reveal) } }

            Divider()

            Button("Move to Trash…", role: .destructive) {
                sessionToDelete = session
            }
        }
    }

    @ViewBuilder
    private func projectAssignmentMenu(for session: ApplePiUISession) -> some View {
        let compatibleProjects = model.projects.filter {
            ProjectDirectoryMatcher.contains(session.workingDirectory, in: $0.workingDirectory)
        }
        if session.projectID != nil || !compatibleProjects.isEmpty {
            Divider()
            if session.projectID != nil {
                Button("Move to Tasks") {
                    Task { await model.move(session, to: nil) }
                }
            }
            if !compatibleProjects.isEmpty {
                Menu("Move to Project") {
                    ForEach(compatibleProjects) { project in
                        Button {
                            Task { await model.move(session, to: project) }
                        } label: {
                            if session.projectID == project.id {
                                Label(project.name, systemImage: "checkmark")
                            } else {
                                Text(project.name)
                            }
                        }
                        .disabled(session.projectID == project.id)
                    }
                }
            }
        }
    }

    private func projectExpansion(_ id: ApplePiProjectID) -> Binding<Bool> {
        Binding(
            get: { expandedProjectIDs.contains(id) },
            set: { expanded in
                if expanded {
                    expandedProjectIDs.insert(id)
                } else {
                    expandedProjectIDs.remove(id)
                }
            }
        )
    }

    private func renameSheet(
        title: String,
        fieldLabel: String,
        text: Binding<String>,
        onCancel: @escaping () -> Void,
        onCommit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField(fieldLabel, text: text)
                .onSubmit(onCommit)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Rename", action: onCommit)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private func commitSessionRename(_ session: ApplePiUISession) {
        let name = sessionRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        sessionToRename = nil
        Task { await model.mutate(session, .rename(name)) }
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { sessionToDelete != nil },
            set: { if !$0 { sessionToDelete = nil } }
        )
    }

    private var removeProjectPresented: Binding<Bool> {
        Binding(
            get: { projectToRemove != nil },
            set: { if !$0 { projectToRemove = nil } }
        )
    }
}

private struct SidebarHoverBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let isVisible: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: ApplePiRadius.compactCard, style: .continuous)
            .fill(ApplePiPalette.accent.opacity(colorScheme == .dark ? 0.12 : 0.08))
            .opacity(isVisible ? 1 : 0)
    }
}

private enum SidebarChromeMetrics {
    static let hoverHeight: CGFloat = 28
    static let hoverSpacing: CGFloat = 2
    static let contentLeadingInset: CGFloat = 12
    static let projectLeadingInset: CGFloat = -2
    static let backgroundHorizontalInset: CGFloat = 6
    static let appHeaderLeadingInset: CGFloat = 8
    static let bottomNavigationLeadingInset: CGFloat = 14
}

/// Owns pointer-only state at the smallest useful boundary so hovering a
/// section header does not invalidate the session/project list above it.
private struct SidebarSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    @Binding var organizationMode: SidebarOrganizationMode
    @Binding var taskSortOrder: ApplePiSidebarTaskSortOrder
    let disclosureIdentifier: String
    let menuIdentifier: String
    let addIdentifier: String
    let addTitle: String
    let addSystemImage: String
    let onAdd: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .regular))
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(isHovered ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
            .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
            .accessibilityIdentifier(disclosureIdentifier)

            Spacer(minLength: 4)

            Menu {
                Section("Organize sidebar") {
                    Picker("Organization", selection: $organizationMode) {
                        ForEach(SidebarOrganizationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }

                Section("Sort chats by") {
                    Picker("Task sorting", selection: $taskSortOrder) {
                        ForEach(ApplePiSidebarTaskSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }
            } label: {
                SidebarActionIcon(systemName: "ellipsis", weight: .medium)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Color(nsColor: .secondaryLabelColor))
            .fixedSize()
            .help("Organize \(title)")
            .accessibilityLabel("Organize \(title)")
            .accessibilityIdentifier(menuIdentifier)
            .opacity(isHovered ? 1 : 0)

            Button(action: onAdd) {
                SidebarActionIcon(systemName: addSystemImage)
            }
            .buttonStyle(.plain)
            .tint(Color(nsColor: .secondaryLabelColor))
            .help(addTitle)
            .accessibilityLabel("\(addTitle) to \(title)")
            .accessibilityIdentifier(addIdentifier)
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.trailing, 8)
        .frame(
            maxWidth: .infinity,
            minHeight: SidebarChromeMetrics.hoverHeight,
            maxHeight: SidebarChromeMetrics.hoverHeight
        )
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .background {
            SidebarHoverBackground(isVisible: isHovered)
                .padding(.leading, -SidebarChromeMetrics.backgroundHorizontalInset)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .contain)
    }
}

private struct SidebarAppHeader: View {
    let onHome: () -> Void
    let onSearch: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onHome) {
                Text("ApplePi")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(Color(nsColor: .labelColor))
            .foregroundStyle(Color(nsColor: .labelColor))
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Home")
            .accessibilityLabel("ApplePi home")
            .accessibilityIdentifier("applepi.app-title")

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 24, height: SidebarChromeMetrics.hoverHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .help("Search projects and tasks (⌘K)")
            .accessibilityLabel("Search projects and tasks")
            .accessibilityIdentifier("applepi.search-button")
        }
        .frame(
            maxWidth: .infinity,
            minHeight: SidebarChromeMetrics.hoverHeight,
            maxHeight: SidebarChromeMetrics.hoverHeight,
            alignment: .leading
        )
    }
}

private struct SidebarBottomNavigation: View {
    let isExtensionsSelected: Bool
    let onOpenExtensions: () -> Void

    var body: some View {
        VStack(spacing: SidebarChromeMetrics.hoverSpacing) {
            Button(action: onOpenExtensions) {
                SidebarUtilityLabel(title: "Extensions", systemName: "puzzlepiece.extension")
                    .sidebarBottomRow(isSelected: isExtensionsSelected)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("applepi.extensions-navigation")

            SettingsLink {
                SidebarUtilityLabel(title: "Settings", systemName: "gearshape")
                    .sidebarBottomRow(isSelected: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("applepi.settings-navigation")
        }
        .padding(.leading, SidebarChromeMetrics.bottomNavigationLeadingInset)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
    }
}

private struct SidebarUtilityLabel: View {
    let title: String
    let systemName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color(nsColor: .labelColor))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarBottomRowModifier: ViewModifier {
    let isSelected: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .frame(
                maxWidth: .infinity,
                minHeight: SidebarChromeMetrics.hoverHeight,
                maxHeight: SidebarChromeMetrics.hoverHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
            .background {
                SidebarHoverBackground(isVisible: isHovered || isSelected)
                    .padding(.leading, -SidebarChromeMetrics.backgroundHorizontalInset)
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct SidebarActionIcon: View {
    let systemName: String
    var weight: Font.Weight = .regular

    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 13, weight: weight))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .frame(width: 20, height: 20)
    }
}

private struct SidebarTaskTitle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let isDraft: Bool
    let isExecuting: Bool
    let isFailed: Bool

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 24.0,
            paused: !isExecuting || reduceMotion
        )) { context in
            Text(title)
                .fontWeight(isDraft || isExecuting || isFailed ? .medium : .regular)
                .foregroundStyle(titleColor)
                .opacity(executionOpacity(at: context.date))
                .lineLimit(1)
        }
    }

    private var titleColor: Color {
        if isFailed { return ApplePiPalette.failure }
        if isExecuting { return ApplePiPalette.running }
        if isDraft { return ApplePiPalette.draft }
        return .primary
    }

    private func executionOpacity(at date: Date) -> Double {
        guard isExecuting, !reduceMotion else { return 1 }
        let phase = sin(date.timeIntervalSinceReferenceDate * .pi * 2 / 1.4)
        return 0.76 + (phase + 1) * 0.12
    }
}

private struct SidebarHoverHighlightModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .sidebarRowChrome(isHovered: isHovered)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct SidebarRowChromeModifier: ViewModifier {
    let isHovered: Bool
    let leadingInset: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(
                maxWidth: .infinity,
                minHeight: SidebarChromeMetrics.hoverHeight,
                maxHeight: SidebarChromeMetrics.hoverHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
            .listRowInsets(
                EdgeInsets(
                    top: SidebarChromeMetrics.hoverSpacing / 2,
                    leading: leadingInset,
                    bottom: SidebarChromeMetrics.hoverSpacing / 2,
                    trailing: 0
                )
            )
            .listRowBackground(
                SidebarHoverBackground(isVisible: isHovered)
                    .padding(.horizontal, SidebarChromeMetrics.backgroundHorizontalInset)
                    .padding(.vertical, SidebarChromeMetrics.hoverSpacing / 2)
            )
    }
}

private extension View {
    func sidebarHoverHighlight() -> some View {
        modifier(SidebarHoverHighlightModifier())
    }

    func sidebarRowChrome(
        isHovered: Bool,
        leadingInset: CGFloat = SidebarChromeMetrics.contentLeadingInset
    ) -> some View {
        modifier(SidebarRowChromeModifier(isHovered: isHovered, leadingInset: leadingInset))
    }

    func sidebarBottomRow(isSelected: Bool) -> some View {
        modifier(SidebarBottomRowModifier(isSelected: isSelected))
    }
}

private struct ProjectSidebarRow: View {
    let project: ApplePiProject
    let taskCount: Int
    @Binding var isExpanded: Bool
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onEdit: () -> Void
    let onReveal: () -> Void
    let onCreateWorktree: () -> Void
    let onArchiveTasks: () -> Void
    let onRemove: () -> Void
    let onCreateTask: () -> Void

    @State private var isHovered = false
    @State private var detailsPresented = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                Image(isExpanded ? "SidebarFolderOpen" : "SidebarFolderClosed")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.white)
                    .frame(width: 16, height: 16)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse \(project.name)" : "Expand \(project.name)")
            .accessibilityLabel(isExpanded ? "Collapse \(project.name)" : "Expand \(project.name)")
            .accessibilityValue(isExpanded ? "Open folder" : "Closed folder")
            .accessibilityIdentifier("applepi.project-folder.\(project.id.rawValue.uuidString)")

            Button {
                onSelect()
                detailsPresented.toggle()
            } label: {
                Text(project.name)
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Project details for \(project.name)")
            .accessibilityIdentifier("applepi.project-details.\(project.id.rawValue.uuidString)")

            Menu {
                projectActions
            } label: {
                SidebarActionIcon(systemName: "ellipsis", weight: .medium)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Color(nsColor: .secondaryLabelColor))
            .fixedSize()
            .help("Project actions")
            .accessibilityLabel("Project actions for \(project.name)")
            .accessibilityIdentifier("applepi.project-menu.\(project.id.rawValue.uuidString)")
            .opacity(showsActions ? 1 : 0)

            Button(action: onCreateTask) {
                SidebarActionIcon(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .tint(Color(nsColor: .secondaryLabelColor))
            .help("New task in \(project.name)")
            .accessibilityLabel("New task in \(project.name)")
            .accessibilityIdentifier("applepi.project-new-task.\(project.id.rawValue.uuidString)")
            .opacity(showsActions ? 1 : 0)
        }
        .padding(.trailing, 8)
        .sidebarRowChrome(
            isHovered: isHovered || detailsPresented,
            leadingInset: SidebarChromeMetrics.projectLeadingInset
        )
        .popover(isPresented: $detailsPresented, arrowEdge: .leading) {
            ProjectDetailsCard(
                project: project,
                taskCount: taskCount,
                onTogglePin: onTogglePin,
                onEdit: {
                    detailsPresented = false
                    onEdit()
                }
            )
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contextMenu { projectActions }
    }

    private var showsActions: Bool { isHovered || detailsPresented }

    @ViewBuilder
    private var projectActions: some View {
        Button(action: onTogglePin) {
            Label(project.isPinned ? "Unpin" : "Pin", systemImage: "pin")
        }
        Button(action: onEdit) {
            Label("Edit", systemImage: "pencil")
        }

        Divider()

        Button(action: onReveal) {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Button(action: onCreateWorktree) {
            Label("Create permanent worktree", systemImage: "arrow.triangle.branch")
        }

        Divider()

        Button(action: onArchiveTasks) {
            Label("Archive tasks", systemImage: "archivebox")
        }
        .disabled(taskCount == 0)

        Divider()

        Button(action: onRemove) {
            Label("Remove project", systemImage: "xmark")
        }
    }
}

private struct ProjectDetailsCard: View {
    let project: ApplePiProject
    let taskCount: Int
    let onTogglePin: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 17)
                    .accessibilityHidden(true)
                Text(project.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button(action: onTogglePin) {
                    Image(systemName: project.isPinned ? "pin.fill" : "pin")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(project.isPinned ? "Unpin project" : "Pin project")
                .accessibilityLabel(project.isPinned ? "Unpin project" : "Pin project")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            ProjectDetailsRow(
                systemImage: "bubble.left",
                title: taskCount == 1 ? "1 task" : "\(taskCount) tasks"
            )

            Divider().padding(.horizontal, 10)

            ProjectDetailsRow(
                systemImage: "folder.badge.gearshape",
                title: project.workingDirectory.lastPathComponent
            )
            ProjectDetailsRow(
                systemImage: "folder",
                title: abbreviatedPath(project.workingDirectory)
            )

            Divider().padding(.horizontal, 10)

            Button(action: onEdit) {
                ProjectDetailsRow(systemImage: "gearshape", title: "Edit project")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 266)
        .padding(.vertical, 4)
        .accessibilityIdentifier("applepi.project-details-card")
    }

    private func abbreviatedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

private struct ProjectDetailsRow: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 17)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }
}

enum ProjectEditorMode: Identifiable {
    case create
    case edit(ApplePiProject)

    var id: String {
        switch self {
        case .create: "create"
        case let .edit(project): "edit-\(project.id.rawValue.uuidString)"
        }
    }

    var project: ApplePiProject? {
        guard case let .edit(project) = self else { return nil }
        return project
    }
}

struct ProjectEditorSheet: View {
    let model: AppModel
    let mode: ProjectEditorMode

    @Environment(\.dismiss) private var dismiss
    @State private var projectName: String
    @State private var sourceFolder: URL?
    @State private var sourceFolderImporterPresented = false
    @State private var removeConfirmationPresented = false
    @FocusState private var projectNameFocused: Bool

    init(model: AppModel, mode: ProjectEditorMode) {
        self.model = model
        self.mode = mode
        _projectName = State(initialValue: mode.project?.name ?? "")
        _sourceFolder = State(initialValue: mode.project?.workingDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(mode.project == nil ? "Create project" : "Edit project")
                    .font(.title3.weight(.semibold))

                Spacer()

                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
                .accessibilityLabel("Close")
            }

            projectNameField
                .padding(.top, 14)

            Text("Source folders")
                .font(.callout.weight(.medium))
                .padding(.top, 15)
                .padding(.bottom, 7)

            sourceFoldersCard

            HStack(spacing: 12) {
                if mode.project != nil {
                    Button("Remove local project", role: .destructive) {
                        removeConfirmationPresented = true
                    }
                    .accessibilityIdentifier("applepi.edit-project.remove")
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(mode.project == nil ? "Create project" : "Save") {
                    commit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCommit)
                .accessibilityIdentifier(commitIdentifier)
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: 500)
        .presentationSizing(.fitted)
        .fileImporter(
            isPresented: $sourceFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let folder = urls.first else { return }
            sourceFolder = folder
            if projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                projectName = suggestedName(for: folder)
            }
        }
        .confirmationDialog(
            "Remove \(mode.project?.name ?? "this project")?",
            isPresented: $removeConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove Project", role: .destructive) {
                guard let project = mode.project else { return }
                dismiss()
                Task { await model.removeProject(project) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its tasks will move to Tasks. No Pi session files or project files will be deleted.")
        }
        .onAppear { projectNameFocused = true }
        .accessibilityIdentifier(sheetIdentifier)
    }

    private var projectNameField: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            TextField("Project name", text: $projectName)
                .textFieldStyle(.plain)
                .focused($projectNameFocused)
                .onSubmit {
                    if canCommit {
                        commit()
                    } else if sourceFolder == nil {
                        sourceFolderImporterPresented = true
                    }
                }
                .accessibilityIdentifier(nameIdentifier)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: ApplePiRadius.compactCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ApplePiRadius.compactCard, style: .continuous)
                .stroke(.separator.opacity(0.7), lineWidth: 0.75)
        }
    }

    private var sourceFoldersCard: some View {
        VStack(spacing: 0) {
            if let sourceFolder {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(suggestedName(for: sourceFolder))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        self.sourceFolder = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove source folder")
                    .accessibilityLabel("Remove source folder")
                }
                .padding(.horizontal, 10)
                .frame(height: 38)

                Divider()
            }

            Button {
                sourceFolderImporterPresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(sourceFolder == nil ? "Add folder" : "Change folder")
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sourceFolder == nil ? "Add source folder" : "Change source folder")
            .accessibilityIdentifier(sourceIdentifier)
        }
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.45),
            in: RoundedRectangle(cornerRadius: ApplePiRadius.compactCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ApplePiRadius.compactCard, style: .continuous)
                .stroke(.separator.opacity(0.65), lineWidth: 0.75)
        }
    }

    private var canCommit: Bool {
        sourceFolder != nil
            && !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sheetIdentifier: String {
        mode.project == nil ? "applepi.create-project-sheet" : "applepi.edit-project-sheet"
    }

    private var nameIdentifier: String {
        mode.project == nil ? "applepi.create-project.name" : "applepi.edit-project.name"
    }

    private var sourceIdentifier: String {
        mode.project == nil ? "applepi.create-project.source-folder" : "applepi.edit-project.source-folder"
    }

    private var commitIdentifier: String {
        mode.project == nil ? "applepi.create-project.commit" : "applepi.edit-project.commit"
    }

    private func suggestedName(for folder: URL) -> String {
        folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
    }

    private func commit() {
        guard let sourceFolder else { return }
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        dismiss()
        Task {
            if let project = mode.project {
                await model.updateProject(project, name: name, workingDirectory: sourceFolder)
            } else {
                await model.addProject(workingDirectory: sourceFolder, name: name)
            }
        }
    }
}

private struct PermanentWorktreeSheet: View {
    let model: AppModel
    let project: ApplePiProject

    @Environment(\.dismiss) private var dismiss
    @State private var branchName: String
    @State private var destination: URL
    @State private var isCreating = false

    init(model: AppModel, project: ApplePiProject) {
        self.model = model
        self.project = project
        let slug = Self.slug(for: project.name)
        let parent = project.workingDirectory.deletingLastPathComponent()
        _branchName = State(initialValue: "worktree/\(slug)")
        _destination = State(initialValue: Self.availableDestination(
            in: parent,
            baseName: "\(project.workingDirectory.lastPathComponent)-worktree"
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Create permanent worktree")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close")
            }

            LabeledContent("Project") {
                Text(project.name).foregroundStyle(.secondary)
            }

            TextField("Branch name", text: $branchName)

            HStack(spacing: 8) {
                Text(destination.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: chooseDestination)
            }

            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { createWorktree() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .presentationSizing(.fitted)
        .accessibilityIdentifier("applepi.create-worktree-sheet")
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Choose Worktree Destination"
        panel.prompt = "Choose"
        panel.directoryURL = destination.deletingLastPathComponent()
        panel.nameFieldStringValue = destination.lastPathComponent
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            destination = url
        }
    }

    private func createWorktree() {
        isCreating = true
        Task {
            let created = await model.createPermanentWorktree(
                for: project,
                branchName: branchName,
                destination: destination
            )
            isCreating = false
            if created {
                dismiss()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }

    private static func slug(for name: String) -> String {
        let pieces = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        let value = pieces.joined(separator: "-")
        return value.isEmpty ? "project" : value
    }

    private static func availableDestination(in parent: URL, baseName: String) -> URL {
        let fileManager = FileManager.default
        var candidate = parent.appending(path: baseName, directoryHint: .isDirectory)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appending(path: "\(baseName)-\(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        return candidate
    }
}
