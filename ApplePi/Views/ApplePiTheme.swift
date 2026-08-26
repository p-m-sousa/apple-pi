import AppKit
import SwiftUI

enum ApplePiRadius {
    static let compactCard: CGFloat = 8
    static let card: CGFloat = 14
}

enum ApplePiPalette {
    static let canvas = adaptive(light: 0xEBE7E4, dark: 0x161D27)
    static let deep = adaptive(light: 0xDACBC2, dark: 0x0D1116)
    static let panel = adaptive(light: 0xF3F2F0, dark: 0x212730)
    static let panelSoft = adaptive(light: 0xF0F2F3, dark: 0x252F3D)
    static let ink = adaptive(light: 0x252F3D, dark: 0xD5D8DB)
    static let muted = adaptive(light: 0x5C5752, dark: 0x8E98A5)
    static let accent = adaptive(light: 0x4B607C, dark: 0x6A9FCC)
    static let draft = adaptive(light: 0x844F3B, dark: 0xE1B06E)
    static let running = adaptive(light: 0x287A48, dark: 0x70CA8D)
    static let failure = adaptive(light: 0xB13A3A, dark: 0xFF7474)

    static let terracotta = Color(hex: 0x844F3B)
    static let sunkissed = Color(hex: 0xE1B06E)
    static let sage = Color(hex: 0xA3A473)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return NSColor(hex: match == .darkAqua ? dark : light)
        })
    }
}
extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

struct ApplePiPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: ApplePiRadius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ApplePiRadius.card, style: .continuous)
                    .stroke(.separator.opacity(0.55), lineWidth: 0.5)
            }
    }
}

struct ApplePiStatusDot: View {
    let state: ApplePiTaskState

    var color: Color {
        switch state {
        case .stopped: .secondary
        case .starting, .queued: ApplePiPalette.sunkissed
        case .ready: ApplePiPalette.sage
        case .generating: ApplePiPalette.running
        case .awaitingInput: ApplePiPalette.terracotta
        case .failed: ApplePiPalette.failure
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityLabel(state.title)
    }
}

private struct ArrowCursorModifier: ViewModifier {
    @State private var isCursorPushed = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    guard !isCursorPushed else { return }
                    NSCursor.arrow.push()
                    isCursorPushed = true
                case .ended:
                    releaseCursor()
                }
            }
            .onDisappear(perform: releaseCursor)
    }

    private func releaseCursor() {
        guard isCursorPushed else { return }
        NSCursor.pop()
        isCursorPushed = false
    }
}

extension View {
    func arrowCursor() -> some View {
        modifier(ArrowCursorModifier())
    }
}
