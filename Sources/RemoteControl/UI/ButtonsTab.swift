import RemoteCore
import SwiftUI

struct ButtonsTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var controller: RemoteController
    @State private var mode: RemoteMode = .remote
    /// The mapping row under the pointer; its button lights up on the remote drawing.
    @State private var hovered: RemoteButton?

    init(initialHover: RemoteButton? = nil) {
        _hovered = State(initialValue: initialHover)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Editing", selection: $mode) {
                ForEach(RemoteMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            HStack(alignment: .top, spacing: 0) {
                RemotePreview(
                    pressed: controller.pressedButtons,
                    hovered: hovered,
                    action: hovered.map { settings.mapping.action(for: $0, in: mode) }
                )
                .frame(width: 168)
                .padding(.top, 18)

                Form {
                    Section {
                        ForEach(RemoteButton.allCases) { button in
                            ButtonMappingRow(
                                button: button,
                                action: binding(for: button),
                                isPressed: controller.pressedButtons.contains(button),
                                isHovered: hovered == button
                            )
                            .onHover { inside in
                                // Moving between rows can report the new row before the old one leaves.
                                if inside { hovered = button } else if hovered == button { hovered = nil }
                            }
                        }
                    } footer: {
                        HStack {
                            Text("Point at a row to find its button on the remote. Press a button on the remote to highlight its row.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset \(mode.shortName) Mode to Defaults") { settings.resetMapping(for: mode) }
                        }
                    }
                }
                .formStyle(.grouped)
                // Let the window background show through so the remote column and the list read as one surface.
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear { mode = settings.mode }
    }

    private func binding(for button: RemoteButton) -> Binding<RemoteAction> {
        Binding(
            get: { settings.mapping.action(for: button, in: mode) },
            set: { settings.mapping.set($0, for: button, in: mode) }
        )
    }
}

/// The remote drawing beside the mapping list, with the pointed-at button's current action underneath.
private struct RemotePreview: View {
    let pressed: Set<RemoteButton>
    let hovered: RemoteButton?
    let action: RemoteAction?

    var body: some View {
        VStack(spacing: 12) {
            RemoteDiagramView(pressed: pressed, touch: nil, highlighted: hovered)
                .frame(width: 104, height: 312)
                .animation(.easeOut(duration: 0.12), value: hovered)
            VStack(spacing: 3) {
                if let hovered, let action {
                    Text(hovered.displayName).font(.callout.weight(.semibold))
                    Text(action.displayName).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Point at a row to find its button")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(width: 148, height: 40, alignment: .top)
        }
    }
}

private struct ButtonMappingRow: View {
    let button: RemoteButton
    @Binding var action: RemoteAction
    let isPressed: Bool
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Image(systemName: button.symbolName)
                    .frame(width: 22)
                    .foregroundStyle(isPressed || isHovered ? Color.accentColor : .secondary)
                Text(button.displayName)
                    .fontWeight(isPressed ? .semibold : .regular)
                Spacer()
                Picker("", selection: kind) {
                    ForEach(ActionKind.Group.allCases) { group in
                        if group.title.isEmpty {
                            ForEach(group.kinds) { Text($0.displayName).tag($0) }
                        } else {
                            Section(group.title) {
                                ForEach(group.kinds) { Text($0.displayName).tag($0) }
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 230)
            }
            if action.kind == .keyboardShortcut {
                ShortcutEditor(shortcut: shortcut)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Grouped forms on macOS ignore listRowBackground, so draw the highlight behind the row content.
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(isPressed ? 0.2 : isHovered ? 0.1 : 0))
                .padding(.horizontal, -8)
                .padding(.vertical, -5)
        )
        .animation(.easeOut(duration: 0.15), value: isPressed)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private var kind: Binding<ActionKind> {
        Binding(
            get: { action.kind },
            set: { newKind in
                var updated = RemoteAction(newKind)
                if newKind == .keyboardShortcut {
                    updated.shortcut = action.shortcut ?? KeyShortcut(keyCode: KeyCatalog.space)
                }
                action = updated
            }
        )
    }

    private var shortcut: Binding<KeyShortcut> {
        Binding(
            get: { action.shortcut ?? KeyShortcut(keyCode: KeyCatalog.space) },
            set: { action.shortcut = $0 }
        )
    }
}

private struct ShortcutEditor: View {
    @Binding var shortcut: KeyShortcut

    var body: some View {
        HStack(spacing: 4) {
            modifierToggle("⌃", .control, help: "Control")
            modifierToggle("⌥", .option, help: "Option")
            modifierToggle("⇧", .shift, help: "Shift")
            modifierToggle("⌘", .command, help: "Command")
            Picker("", selection: $shortcut.keyCode) {
                ForEach(KeyCatalog.all) { Text($0.name).tag($0.code) }
            }
            .labelsHidden()
            .frame(width: 130)
        }
    }

    private func modifierToggle(_ symbol: String, _ modifier: ModifierSet, help: String) -> some View {
        Toggle(symbol, isOn: Binding(
            get: { shortcut.modifiers.contains(modifier) },
            set: { on in
                if on { shortcut.modifiers.insert(modifier) } else { shortcut.modifiers.remove(modifier) }
            }
        ))
        .toggleStyle(.button)
        .help(help)
    }
}
