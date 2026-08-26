import SwiftUI

struct ApplePiCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") {
                Task { await model.createTask() }
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Task in Current Project") {
                guard let currentProject else { return }
                Task { await model.createTask(in: currentProject) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(currentProject == nil)

            Divider()

            Button("Add Project…") {
                model.projectImporterPresented = true
            }
        }

        CommandMenu("Task") {
            Button("Refresh") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Abort Current Turn") {
                Task { await model.abortSelectedTask() }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(model.selectedSession == nil)

            Button("Stop Pi Runtime") {
                Task { await model.stopSelectedRuntime() }
            }
            .disabled(model.selectedSession?.state.isLive != true)

            Divider()

            Button(model.inspectorPresented ? "Hide Inspector" : "Show Inspector") {
                model.inspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model.selectedSession == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Extensions") {
                model.selection = .extensions
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }

    private var currentProject: ApplePiProject? {
        guard let projectID = model.selectedProjectID else { return nil }
        return model.projects.first { $0.id == projectID }
    }
}
