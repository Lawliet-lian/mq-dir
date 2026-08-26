import AppKit
import SwiftUI

/// 便捷宏：从主 bundle 读取本地化字符串
/// （与 NSLocalizedString 默认行为一致，但允许在表达式中使用）
private func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    if args.isEmpty { return format }
    return String(format: format, arguments: args)
}

// MARK: - Color scheme picker helpers

extension ColorSchemeOption {
    /// Map the persisted preference onto SwiftUI's `.preferredColorScheme`.
    /// `.system` becomes `nil` so the modifier becomes a no-op and macOS's
    /// own Appearance setting wins.
    var preferred: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }

    /// 本地化显示标签（从 Localizable.strings 读取）
    var label: String {
        switch self {
        case .system: L("mqdir.colorScheme.system")
        case .light:  L("mqdir.colorScheme.light")
        case .dark:   L("mqdir.colorScheme.dark")
        }
    }
}

// MARK: - Language picker helpers

extension LanguageOption {
    /// 本地化显示标签（从 Localizable.strings 读取）
    var label: String {
        switch self {
        case .system:  L("mqdir.language.system")
        case .english: L("mqdir.language.english")
        case .chinese: L("mqdir.language.chinese")
        }
    }
}

/// macOS Settings scene contents. Three sections: Appearance picker
/// + Language picker + Shortcuts customiser for the 10 actions exposed in
/// `ShortcutAction`. Both write through `WorkspaceManager` so the
/// debounced save path is shared with everything else workspace-
/// scoped (favourites, project list, …).
struct SettingsView: View {
    @ObservedObject var workspace: WorkspaceManager
    @State private var editingAction: ShortcutAction?

    var body: some View {
        Form {
            Section(L("mqdir.settings.section.appearance")) {
                Picker(L("mqdir.settings.appearance.pickerLabel"), selection: appearanceBinding) {
                    ForEach(ColorSchemeOption.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section(L("mqdir.settings.section.language")) {
                Picker(L("mqdir.settings.language.pickerLabel"), selection: languageBinding) {
                    ForEach(LanguageOption.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                Stepper(value: sidebarDefaultWidthBinding, in: 0...280, step: 1) {
                    HStack {
                        Text(L("mqdir.settings.sidebar.defaultWidth"))
                        Spacer()
                        Text(
                            L(
                                "mqdir.settings.sidebar.defaultWidthValue",
                                Int(sidebarDefaultWidthBinding.wrappedValue)
                            )
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L("mqdir.settings.section.sidebar"))
            } footer: {
                Text(L("mqdir.settings.sidebar.defaultWidthFooter"))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("mqdir.settings.filenames.normalizeHangul"), isOn: normalizeHangulBinding)
            } header: {
                Text(L("mqdir.settings.section.filenames"))
            } footer: {
                Text(L("mqdir.settings.filenames.normalizeHangulFooter"))
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    shortcutRow(action)
                }
                HStack {
                    Spacer()
                    Button(L("mqdir.settings.shortcuts.restoreDefaults")) {
                        workspace.resetAllShortcutOverrides()
                    }
                    .disabled(workspace.workspace.settings.shortcutOverrides.isEmpty)
                }
            } header: {
                Text(L("mqdir.settings.section.shortcuts"))
            } footer: {
                Text(L("mqdir.settings.shortcuts.footer"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
        .sheet(item: $editingAction) { action in
            KeyCaptureSheet(
                action: action,
                conflictChecker: { binding in
                    conflictingAction(for: binding, ignoring: action)
                },
                onCommit: { binding in
                    workspace.setShortcutBinding(binding, for: action)
                }
            )
        }
    }

    // MARK: - Bindings

    private var appearanceBinding: Binding<ColorSchemeOption> {
        Binding(
            get: { workspace.workspace.settings.colorScheme },
            set: { workspace.setColorScheme($0) }
        )
    }

    private var languageBinding: Binding<LanguageOption> {
        Binding(
            get: { workspace.workspace.settings.language },
            set: { workspace.setLanguage($0) }
        )
    }

    private var normalizeHangulBinding: Binding<Bool> {
        Binding(
            get: { workspace.workspace.settings.normalizeHangulOnDragOut },
            set: { workspace.setNormalizeHangulOnDragOut($0) }
        )
    }

    private var sidebarDefaultWidthBinding: Binding<Double> {
        Binding(
            get: {
                workspace.workspace.settings.sidebarDefaultWidth
                    ?? Double(Theme.Metrics.sidebarWidth)
            },
            set: { workspace.setSidebarDefaultWidth($0) }
        )
    }

    // MARK: - Shortcut rows

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let active = workspace.workspace.settings.binding(for: action)
        let isOverridden = workspace.workspace.settings.shortcutOverrides[action] != nil
        return HStack {
            Text(action.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                editingAction = action
            } label: {
                Text(active.displayString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.gray.opacity(0.3), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help(L("mqdir.settings.shortcuts.recordHint"))
            if isOverridden {
                Button {
                    workspace.setShortcutBinding(nil, for: action)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(L("mqdir.settings.shortcuts.resetHint"))
            }
        }
    }

    /// Look for an existing customisable action already bound to
    /// `candidate`, ignoring the action currently being edited so
    /// re-saving an unchanged shortcut doesn't flag itself as a
    /// conflict. Only checks the customisable set — collisions with
    /// hardcoded shortcuts (Cut/Copy/Paste, system menus) are not
    /// surfaced because we can't repoint those from this UI.
    private func conflictingAction(
        for candidate: ShortcutBinding,
        ignoring: ShortcutAction
    ) -> ShortcutAction? {
        for action in ShortcutAction.allCases where action != ignoring {
            if workspace.workspace.settings.binding(for: action) == candidate {
                return action
            }
        }
        return nil
    }
}

extension ShortcutAction: Identifiable {
    public var id: String { rawValue }
}

/// Modal that records the next keyDown the user types and either
/// commits it as a binding or surfaces a conflict explanation. The
/// background NSView grabs `keyDown(with:)` directly so we receive
/// the literal modifier flags + keyCode without going through
/// SwiftUI's `.onKeyPress`, which doesn't expose modifier-only
/// captures reliably on macOS 14.
struct KeyCaptureSheet: View {
    let action: ShortcutAction
    let conflictChecker: (ShortcutBinding) -> ShortcutAction?
    let onCommit: (ShortcutBinding) -> Void

    @State private var captured: ShortcutBinding?
    @State private var conflictWith: ShortcutAction?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text(L("mqdir.settings.capture.title", action.label))
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.10))
                Text(captured?.displayString ?? L("mqdir.settings.capture.prompt"))
                    .font(.system(size: 22, design: .monospaced))
                    .foregroundStyle(captured == nil ? .secondary : .primary)
            }
            .frame(height: 80)

            if let conflictWith {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L("mqdir.settings.capture.conflict", conflictWith.label))
                        .foregroundStyle(.primary)
                }
                .font(.system(size: 11))
            } else if captured != nil {
                Text(L("mqdir.settings.capture.ok"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text(L("mqdir.settings.capture.modifierOnly"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button(L("mqdir.common.cancel")) { dismiss() }
                Spacer()
                Button(L("mqdir.common.save")) {
                    if let captured, conflictWith == nil {
                        onCommit(captured)
                        dismiss()
                    }
                }
                .disabled(captured == nil || conflictWith != nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(KeyCaptureView(
            captured: $captured,
            onBareEscape: { dismiss() }
        ))
        .onChange(of: captured) { _, new in
            guard let new else { conflictWith = nil; return }
            conflictWith = conflictChecker(new)
        }
    }
}

/// SwiftUI bridge that hosts an `NSView` whose only job is to grab
/// `keyDown` events while the capture sheet is open. The view
/// makes itself first responder on appearance so the user can
/// type a key combination immediately without clicking into the
/// sheet first. A bare Esc (no modifiers) routes through
/// `onBareEscape` so the sheet can dismiss instead of binding
/// `⎋` to the action.
private struct KeyCaptureView: NSViewRepresentable {
    @Binding var captured: ShortcutBinding?
    var onBareEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCaptureNSView()
        view.onCapture = { binding in
            DispatchQueue.main.async {
                self.captured = binding
            }
        }
        view.onBareEscape = { DispatchQueue.main.async(execute: onBareEscape) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class KeyCaptureNSView: NSView {
    var onCapture: ((ShortcutBinding) -> Void)?
    var onBareEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Async so the window has finished installing the sheet's
        // responder chain by the time we ask for first-responder
        // status.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = ShortcutModifiers(eventFlags: event.modifierFlags)
        // Bare Esc (no modifiers) is the conventional cancel
        // gesture for a macOS sheet; route it to dismiss instead
        // of letting the user accidentally bind ⎋ to the action.
        // ⎋ with a modifier (e.g. ⌥⎋) still captures normally.
        if event.keyCode == 53 && modifiers.isEmpty {
            onBareEscape?()
            return
        }
        // F1...F12 by hardware keyCode. Reading
        // `charactersIgnoringModifiers` works too (Apple maps them to
        // NSF<N>FunctionKey = 0xF704...0xF70F) but the keyCode table
        // is more obvious and skips the function-row's IR/mute/etc.
        // overlay codes that share the same physical position on
        // some Mac keyboards.
        let fnByKeyCode: [UInt16: Int] = [
            122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6,
            98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
        ]

        let key: ShortcutKey
        switch event.keyCode {
        case 51:  key = .delete
        case 36:  key = .return
        case 53:  key = .escape
        case 48:  key = .tab
        case 126: key = .upArrow
        case 125: key = .downArrow
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        default:
            if let fn = fnByKeyCode[event.keyCode] {
                key = .functionKey(fn)
                break
            }
            guard let chars = event.charactersIgnoringModifiers,
                  let first = chars.first
            else { return }
            // Persist as lowercase so a user typing Shift+T and a
            // user typing T into the capture box collapse to the
            // same binding. The macOS menu bar uppercases letter
            // glyphs at render time anyway.
            key = .character(Character(String(first).lowercased()))
        }
        onCapture?(ShortcutBinding(key: key, modifiers: modifiers))
    }
}
