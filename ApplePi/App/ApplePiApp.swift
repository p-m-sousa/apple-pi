import AppKit
import SwiftUI

@main
@MainActor
struct ApplePiApp: App {
    @NSApplicationDelegateAdaptor(ApplePiAppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        let services = ApplePiServiceAdapter()
        services.attach(to: model)
        _model = State(initialValue: model)
        NSApplication.shared.appearance = model.appearance.applicationAppearance
        AppLifecycleBridge.shared.model = model
        AppLifecycleBridge.shared.services = services
    }

    var body: some Scene {
        WindowGroup("ApplePi", id: "main") {
            MainSurfaceView(model: model)
                .frame(minWidth: 900, minHeight: 620)
                .applePiAppearance(model.appearance)
                .task {
                    await model.bootstrap()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            ApplePiCommands(model: model)
        }

        WindowGroup("Pi Terminal", for: UUID.self) { $requestID in
            TerminalWindowView(request: requestID.flatMap { model.terminalRequest(id: $0) })
                .frame(minWidth: 700, minHeight: 450)
                .applePiAppearance(model.appearance)
                .onDisappear {
                    if let requestID {
                        model.releaseTerminalRequest(id: requestID)
                    }
                }
        }
        .defaultSize(width: 920, height: 620)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(model: model)
                .applePiAppearance(model.appearance)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class ApplePiAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppLifecycleBridge.shared.model?.hasLiveTasks == true else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit while Pi is working?"
        alert.informativeText = "Active tasks and extension-backed runtimes will stop. Session history already written by Pi remains available."
        alert.addButton(withTitle: "Quit and Stop Tasks")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            await AppLifecycleBridge.shared.services?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class AppLifecycleBridge {
    static let shared = AppLifecycleBridge()
    weak var model: AppModel?
    var services: ApplePiServiceAdapter?
}

extension ApplePiAppearance {
    var applicationAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

private struct ApplePiAppearanceModifier: ViewModifier {
    let appearance: ApplePiAppearance

    func body(content: Content) -> some View {
        content
            .onAppear {
                apply(appearance)
            }
            .onChange(of: appearance) { _, newAppearance in
                apply(newAppearance)
            }
    }

    private func apply(_ appearance: ApplePiAppearance) {
        NSApplication.shared.appearance = appearance.applicationAppearance
    }
}

private extension View {
    func applePiAppearance(_ appearance: ApplePiAppearance) -> some View {
        modifier(ApplePiAppearanceModifier(appearance: appearance))
    }
}
