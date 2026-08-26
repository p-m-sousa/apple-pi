import AppKit
import SwiftUI
#if canImport(SwiftTerm)
@preconcurrency import SwiftTerm
#endif

struct TerminalWindowView: View {
    let request: ApplePiTerminalRequest?
    @State private var exitMessage: String?

    var body: some View {
        Group {
            if let request {
                ZStack(alignment: .bottom) {
#if canImport(SwiftTerm)
                    PiTerminalRepresentable(request: request) { exitCode in
                        if let exitCode {
                            exitMessage = "Pi exited with status \(exitCode)."
                        } else {
                            exitMessage = "The Pi process ended."
                        }
                    }
#else
                    ContentUnavailableView {
                        Label("Terminal renderer unavailable", systemImage: "terminal")
                    } description: {
                        Text("Build ApplePi with the pinned SwiftTerm package to use Pi's full TUI.")
                    }
#endif
                    if let exitMessage {
                        Text(exitMessage)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(12)
                    }
                }
                .navigationTitle(request.title)
            } else {
                ContentUnavailableView("No Terminal Request", systemImage: "terminal")
            }
        }
        .background(ApplePiPalette.deep)
    }
}

#if canImport(SwiftTerm)
private struct PiTerminalRepresentable: NSViewRepresentable {
    let request: ApplePiTerminalRequest
    let onExit: (Int32?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onExit: onExit)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeForegroundColor = NSColor(hex: 0xD5D8DB)
        terminal.nativeBackgroundColor = NSColor(hex: 0x0D1116)
        terminal.caretColor = NSColor(hex: 0x6A9FCC)
        terminal.layer?.backgroundColor = NSColor(hex: 0x0D1116).cgColor
        terminal.optionAsMetaKey = true
        terminal.allowMouseReporting = true
        terminal.startProcess(
            executable: request.executable,
            args: request.arguments,
            environment: request.environment.isEmpty ? nil : request.environment,
            execName: request.executable,
            currentDirectory: request.currentDirectory
        )
        return terminal
    }

    func updateNSView(_ terminal: LocalProcessTerminalView, context: Context) {
        context.coordinator.onExit = onExit
    }

    static func dismantleNSView(_ terminal: LocalProcessTerminalView, coordinator: Coordinator) {
        if terminal.process.running {
            terminal.terminate()
        }
        terminal.processDelegate = nil
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: (Int32?) -> Void

        init(onExit: @escaping (Int32?) -> Void) {
            self.onExit = onExit
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) { onExit(exitCode) }
    }
}
#endif
