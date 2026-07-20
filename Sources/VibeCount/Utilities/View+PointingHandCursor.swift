import SwiftUI
import AppKit

/// Shows the pointing-hand cursor while the pointer is over a `.plain`-styled
/// button so it still reads as clickable.
///
/// Tracks whether *this* view pushed the cursor and pops only its own push, so
/// the `NSCursor` stack stays balanced even when the view is removed mid-hover
/// (e.g. the popover closes) — the case that otherwise leaves the pointing hand
/// stuck system-wide.
///
/// - Note: On macOS 15+ this whole dance is replaceable by the native
///   `.pointerStyle(.link)` modifier.
struct PointingHandCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    guard !pushed else { return }
                    NSCursor.pointingHand.push()
                    pushed = true
                } else {
                    guard pushed else { return }
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                guard pushed else { return }
                NSCursor.pop()
                pushed = false
            }
    }
}

extension View {
    /// Shows the pointing-hand cursor on hover; see `PointingHandCursor`.
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }
}
