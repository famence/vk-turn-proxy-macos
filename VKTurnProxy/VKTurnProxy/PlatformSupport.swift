// PlatformSupport.swift
//
// AppKit shims for the handful of things SwiftUI can't do cross-platform.
// The iOS build reached for UIKit here (UIActivityViewController,
// UIDocumentPickerViewController, UIPasteboard, UITextView, systemGray6…).
// On macOS the equivalents are AppKit (NSSavePanel / NSOpenPanel /
// NSPasteboard / NSTextView / NSColor) — collected in this one file so the
// views stay declarative and the platform quirks are contained.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - iOS-only view-modifier shims
//
// These modifiers exist only on iOS. Providing no-op macOS versions lets the
// shared SwiftUI view code call them unchanged instead of sprinkling `#if
// os(iOS)` around every text field.

/// Stand-in for UIKit's `UITextAutocapitalizationType` so `.autocapitalization(.none)`
/// keeps parsing. AppKit text fields never auto-capitalize, so it's a no-op.
enum TextAutocapitalizationShim { case none, words, sentences, allCharacters }

/// Stand-in for UIKit's `UIKeyboardType` so `.keyboardType(...)` keeps parsing.
/// macOS has a hardware keyboard, so it's a no-op.
enum KeyboardTypeShim { case numbersAndPunctuation, numberPad, decimalPad, URL, emailAddress, `default` }

extension View {
    /// No-op on macOS (AppKit text fields don't autocapitalize).
    func autocapitalization(_ style: TextAutocapitalizationShim) -> some View { self }
    /// No-op on macOS (no soft keyboard).
    func keyboardType(_ type: KeyboardTypeShim) -> some View { self }
}

// MARK: - Cross-platform colors

extension Color {
    /// The subtle "grouped content" fill iOS gets from `Color(.systemGray6)`.
    /// AppKit's closest analogue for a resting control background is
    /// `NSColor.controlBackgroundColor` blended toward the window; using
    /// `underPageBackgroundColor` gives the same soft, slightly-recessed look
    /// for the stat tiles.
    static var platformGroupedFill: Color {
        Color(nsColor: .underPageBackgroundColor)
    }

    /// The window/content background — iOS `Color(.systemBackground)`.
    static var platformBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}

// MARK: - Pasteboard

enum Pasteboard {
    /// Current clipboard string, or nil. Mirrors `UIPasteboard.general.string`.
    static var string: String? {
        NSPasteboard.general.string(forType: .string)
    }
}

// MARK: - Save / Open panels

/// macOS-native file export/import, presented imperatively from a button
/// action (the AppKit idiom) rather than embedded in a SwiftUI `.sheet` the
/// way UIDocumentPicker / UIActivityViewController were on iOS.
enum MacFilePanels {

    /// Copy an already-written temp file to a user-chosen destination via
    /// NSSavePanel. Used by "Export Full Backup" and "Share logs". Runs the
    /// panel app-modally and copies on confirm. `onError` surfaces a copy
    /// failure so the caller can show the same alert the iOS share-sheet
    /// error path used.
    static func exportCopy(of sourceURL: URL,
                           suggestedName: String,
                           onError: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: sourceURL, to: dest)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    /// Pick a single file via NSOpenPanel, restricted to the given content
    /// types. Mirrors the iOS DocumentPicker; the caller's completion runs
    /// with the chosen security-scoped URL (BackupManager.importFromFileURL
    /// handles start/stopAccessingSecurityScopedResource internally).
    static func importFile(contentTypes: [UTType],
                           onPicked: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if !contentTypes.isEmpty {
            panel.allowedContentTypes = contentTypes
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onPicked(url)
        }
    }
}

// MARK: - Log text view (NSTextView)

/// NSTextView wrapper for the Logs screen — handles very large log text
/// without the SwiftUI layout blow-up a plain `Text` would hit. AppKit
/// counterpart of the iOS UITextView-based `LogTextView`.
struct LogTextView: NSViewRepresentable {
    let text: String
    let autoScroll: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.textColor = .labelColor
        tv.backgroundColor = .textBackgroundColor
        tv.drawsBackground = true
        tv.textContainerInset = NSSize(width: 4, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            if autoScroll && !text.isEmpty {
                tv.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
            }
        }
    }
}
