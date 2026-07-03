// Sources/VibeCount/Utilities/Clipboard.swift
import AppKit

/// Thin wrapper around `NSPasteboard` so copy behavior can be unit-tested
/// against a throwaway pasteboard instead of clobbering the user's real
/// clipboard. UI code calls `Clipboard.copy(_:)`; tests pass an explicit
/// scratch pasteboard.
enum Clipboard {
    /// Replaces the pasteboard's contents with `string`, returning whether the
    /// write succeeded. Defaults to the general (system) pasteboard.
    @discardableResult
    static func copy(_ string: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }
}
