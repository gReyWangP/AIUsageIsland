import AppKit
import Carbon
import Combine
import SwiftUI

enum ShortcutAction: UInt32, Codable, CaseIterable, Identifiable {
    case toggle = 1, hide = 2, refresh = 3
    var id: UInt32 { rawValue }
    var title: String {
        switch self { case .toggle: "展开／收起详情"; case .hide: "收起浮窗"; case .refresh: "刷新用量" }
    }
}
struct KeyboardShortcut: Codable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String
    var isValid: Bool {
        !keyLabel.isEmpty && keyCode < 128 && modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
            && modifiers & ~UInt32(cmdKey | controlKey | optionKey | shiftKey) == 0
    }
    var label: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map { $0.1 }.joined() + keyLabel
    }
    func matches(_ other: Self) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }
    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var flags: UInt32 = 0
        if event.modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
        modifiers = flags
        var special: [UInt16: String] = [49: "空格", 36: "↩", 48: "⇥", 51: "⌫", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        for (index, code) in [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20].enumerated() {
            special[UInt16(code)] = "F\(index + 1)"
        }
        keyLabel = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "键\(keyCode)"
    }
}
enum ShortcutValidation {
    static func error(for key: KeyboardShortcut, action: ShortcutAction, bindings: [ShortcutAction: KeyboardShortcut]) -> String? {
        guard key.isValid else { return "快捷键至少包含 ⌘、⌃ 或 ⌥，不能只用普通按键。" }
        if let duplicate = ShortcutAction.allCases.first(where: { $0 != action && bindings[$0]?.matches(key) == true }) {
            return "此快捷键已用于\(duplicate.title)"
        }
        return nil
    }
}

@MainActor
final class GlobalShortcutController: ObservableObject {
    @Published private(set) var error: String?
    private let settings: IslandSettings
    private let perform: (ShortcutAction) -> Void
    private var references: [ShortcutAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var suspended = false
    private static let signature: OSType = 0x41495549

    init(settings: IslandSettings, perform: @escaping (ShortcutAction) -> Void) {
        self.settings = settings; self.perform = perform
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else { return result }
            let controller = Unmanaged<GlobalShortcutController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if identifier.signature == GlobalShortcutController.signature,
                   let action = ShortcutAction(rawValue: identifier.id) { controller.perform(action) }
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if result != noErr { error = "系统快捷键监听暂不可用（\(result)）" }
        else { restore() }
    }
    private func unregisterAll() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll()
    }
    private func register(_ bindings: [ShortcutAction: KeyboardShortcut]) throws {
        for action in ShortcutAction.allCases {
            guard let key = bindings[action] else { continue }
            if let error = ShortcutValidation.error(for: key, action: action, bindings: bindings) {
                throw NSError(domain: "Shortcut", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
            }
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(key.keyCode, key.modifiers,
                EventHotKeyID(signature: Self.signature, id: action.rawValue), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
            guard result == noErr, let reference else {
                throw NSError(domain: "Shortcut", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "快捷键 \(key.label) 已被系统或其他应用占用（\(result)）"])
            }
            references[action] = reference
        }
    }
    func suspend() { suspended = true; unregisterAll() }
    func restore() {
        guard eventHandler != nil else { return }
        suspended = false
        unregisterAll()
        var issues: [String] = []
        for action in ShortcutAction.allCases {
            guard let key = settings.shortcutBindings[action] else { continue }
            if let issue = ShortcutValidation.error(for: key, action: action, bindings: settings.shortcutBindings) {
                issues.append(issue); continue
            }
            do { try register([action: key]) }
            catch { issues.append(error.localizedDescription) }
        }
        if !issues.isEmpty { error = issues.joined(separator: "；") }
    }
    func set(_ key: KeyboardShortcut?, for action: ShortcutAction) {
        guard eventHandler != nil else { error = "系统快捷键监听暂不可用，请重新打开应用。"; return }
        if let key, let error = ShortcutValidation.error(for: key, action: action, bindings: settings.shortcutBindings) {
            self.error = error; return
        }
        let previous = settings.shortcutBindings[action]
        if let reference = references.removeValue(forKey: action) { UnregisterEventHotKey(reference) }
        do {
            if let key { try register([action: key]) }
            settings.shortcutBindings[action] = key
            error = nil
        } catch {
            if let previous { try? register([action: previous]) }
            self.error = error.localizedDescription
        }
        if suspended { unregisterAll() }
    }
    func shutdown() {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: KeyboardShortcut?
    var onStart: () -> Void
    var onCapture: (KeyboardShortcut) -> Void
    var onStop: () -> Void
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.target = button; button.action = #selector(RecorderButton.startRecording)
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.currentTitle = shortcut?.label ?? "点击录制"
        button.onStart = onStart; button.onCapture = onCapture; button.onStop = onStop
        if !button.recording { button.title = button.currentTitle }
        button.setAccessibilityLabel("快捷键，" + button.currentTitle)
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.stopRecording() }
}

final class RecorderButton: NSButton {
    var currentTitle = "点击录制"
    private var keyMonitor: Any?
    var recording = false
    var onStart: () -> Void = {}
    var onCapture: (KeyboardShortcut) -> Void = { _ in }
    var onStop: () -> Void = {}
    override var acceptsFirstResponder: Bool { true }
    @objc func startRecording() {
        guard !recording else { return }
        recording = true; title = "按组合键 · Esc 取消"
        onStart(); window?.makeFirstResponder(self)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let captured = MainActor.assumeIsolated {
                guard let self, self.recording, event.window === self.window else { return false }
                self.keyDown(with: event)
                return true
            }
            return captured ? nil : event
        }
    }
    func stopRecording() {
        guard recording else { return }
        recording = false; title = currentTitle
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        onStop()
    }
    override func resignFirstResponder() -> Bool { stopRecording(); return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode != 53 || !modifiers.isEmpty { onCapture(KeyboardShortcut(event: event)) }
        stopRecording()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
}
