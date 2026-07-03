// Sources/VibeCount/UI/InviteCodeButton.swift
import SwiftUI
import AppKit

/// A one-tap-to-copy pill showing the local user's invite code.
///
/// Clicking anywhere on the pill writes the code to the system pasteboard and
/// briefly swaps the copy glyph/label for a "Copied!" confirmation before
/// reverting. Hovering highlights the pill and switches to the pointing-hand
/// cursor so it reads as interactive.
struct InviteCodeButton: View {
    let inviteCode: String

    @State private var copied = false
    @State private var isHovered = false
    @State private var resetTask: Task<Void, Never>?

    // One shape shared by the fill, border, and hit-test region so they can't
    // drift out of sync.
    private let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                // Status label soft-blur crossfades between the two states.
                ZStack(alignment: .leading) {
                    // Invisible spacer pins the width to the wider label so the
                    // code + icon on the right never shift while the two states
                    // overlap mid-transition.
                    Text("Invite Code").hidden()

                    // `.id(copied)` gives each state a distinct identity so the
                    // switch reads as remove-old + insert-new — which is what
                    // drives the blur transition (a plain content swap wouldn't).
                    Text(copied ? "Copied!" : "Invite Code")
                        .foregroundColor(copied ? .green : .secondary)
                        .id(copied)
                        .transition(.blurReplace)
                }
                .font(.caption)

                Text(inviteCode)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .fontWeight(.bold)

                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.caption)
                    .imageScale(.small)
                    .foregroundColor(copied ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(shape.fill(Color.primary.opacity(isHovered ? 0.08 : 0.04)))
            .overlay(shape.strokeBorder(Color.primary.opacity(isHovered ? 0.14 : 0.07), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied to clipboard" : "Click to copy your invite code")
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        // Cursor push/pop balancing and disappear cleanup live in the shared
        // modifier; this view only tracks `isHovered` for its own highlight.
        .pointingHandCursor()
        .onHover { isHovered = $0 }
        .onDisappear { resetTask?.cancel() }
    }

    private func copy() {
        writeCode()

        withAnimation(.easeInOut(duration: 0.32)) {
            copied = true
        }

        // Revert the confirmation after a short beat; cancel any in-flight
        // reset so rapid repeat clicks keep the "Copied!" state visible.
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.32)) {
                copied = false
            }
        }
    }

    /// Writes the invite code to `pasteboard`, returning whether it succeeded.
    /// Split out from `copy()`'s animation so the "copies its own code" wiring
    /// is unit-testable against a scratch pasteboard, without driving SwiftUI
    /// state. Defaults to the system pasteboard.
    @discardableResult
    func writeCode(to pasteboard: NSPasteboard = .general) -> Bool {
        Clipboard.copy(inviteCode, to: pasteboard)
    }
}
