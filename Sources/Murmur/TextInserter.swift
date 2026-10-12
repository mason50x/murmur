import AppKit
import ApplicationServices

/// Decides where a transcript goes and pastes it with ⌘V, preserving the clipboard:
/// - a text field has focus → paste
/// - something else clearly has focus (a web page, a list, the desktop) → show the copy card
/// - the app won't say (no accessibility info) → paste, and show the card in case it missed
@MainActor
enum TextInserter {
    struct Target {
        /// Field text on either side of the caret, when the app exposes it.
        let before: String?
        let after: String?
        /// False for single-line fields (search boxes, URL bars), which can't take paragraphs.
        var multiline = true
    }

    enum Delivery {
        case paste(Target)
        case pasteAndShow(Target)
        case show
    }

    /// Terminals and code editors: always paste, formatted as a standalone sentence.
    private static let alwaysPaste: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "dev.zed.Zed-Preview",
    ]

    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField",
    ]
    private static let singleLineRoles: Set<String> = [
        kAXTextFieldRole as String, kAXComboBoxRole as String, "AXSearchField",
    ]

    /// Ask Electron/Chromium apps to build their accessibility tree. Called when recording starts
    /// so it's ready by the time we check focus.
    static func primeFrontmostApp() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func delivery() -> Delivery {
        guard let app = NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return .show }
        if let id = app.bundleIdentifier, alwaysPaste.contains(id) {
            return .paste(Target(before: nil, after: nil))
        }
        guard let focused = focusedElement(of: app) else {
            return .pasteAndShow(Target(before: nil, after: nil))
        }
        guard isEditable(focused) else { return .show }
        let context = caretContext(focused)
        let role: String? = copy(focused, kAXRoleAttribute)
        return .paste(Target(
            before: context?.before, after: context?.after, multiline: !singleLineRoles.contains(role ?? "")))
    }

    private static func isEditable(_ el: AXUIElement) -> Bool {
        let role: String? = copy(el, kAXRoleAttribute)
        if let role, textRoles.contains(role) { return true }
        if let editable: Bool = copy(el, "AXEditable"), editable { return true }
        if (copy(el, "AXEditableAncestor") as AXUIElement?) != nil { return true }
        var settable: DarwinBoolean = false
        if role != "AXWebArea",
            AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
            settable.boolValue,
            (copy(el, kAXSelectedTextRangeAttribute) as AXValue?) != nil
        {
            return true
        }
        return false
    }

    private static func focusedElement(of app: NSRunningApplication) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.2)
        return copy(appEl, kAXFocusedUIElementAttribute)
    }

    /// Text before/after the caret, if the focused element exposes its value and selection.
    private static func caretContext(_ el: AXUIElement) -> (before: String, after: String)? {
        guard let value: String = copy(el, kAXValueAttribute),
            let rangeValue: AXValue = copy(el, kAXSelectedTextRangeAttribute)
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        let utf16 = value.utf16
        guard range.location >= 0, range.location + range.length <= utf16.count else { return nil }
        let start = utf16.index(utf16.startIndex, offsetBy: range.location)
        let end = utf16.index(start, offsetBy: range.length)
        // A selection gets replaced, so context is what surrounds it.
        guard let before = String(utf16[..<start]), let after = String(utf16[end...]) else { return nil }
        return (before, after)
    }

    /// Pastes `text` (or its paragraph/list `layout`, where the caret has a line to itself) with ⌘V,
    /// then restores the previous clipboard contents.
    static func paste(_ text: String, layout: String?, into target: Target) {
        let useLayout = target.multiline && SmartFormat.allowsLayout(before: target.before, after: target.after)
        let output = SmartFormat.apply(useLayout ? layout ?? text : text, before: target.before, after: target.after)
        let pb = NSPasteboard.general
        let saved = snapshot(pb)

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(output, forType: .string)
        // Tell clipboard managers this is transient.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pb.writeObjects([item])
        let ourChange = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pb.changeCount == ourChange else { return }
            restore(saved, to: pb)
        }
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Pasteboard snapshot

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(restored)
    }

    // MARK: - AX helpers

    private static func copy<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        } else if T.self == AXValue.self {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        }
        return value as? T
    }
}
