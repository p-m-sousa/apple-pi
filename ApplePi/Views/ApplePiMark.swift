import SwiftUI

/// Shared in-app rendering of the ApplePi brand artwork.
struct ApplePiMark: View {
    var body: some View {
        Image("ApplePiMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityHidden(true)
    }
}
