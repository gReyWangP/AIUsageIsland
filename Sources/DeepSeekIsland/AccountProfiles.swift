import Foundation

struct AccountProfileEntry: Codable, Equatable, Identifiable {
    static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let id: UUID
    var label: String
    var identity: String? = nil
    var isLegacy: Bool { id == Self.legacyID }
}
struct AccountProfiles: Codable, Equatable {
    private var items: [String: [AccountProfileEntry]] = [:]
    private var selection: [String: UUID] = [:]
    func entries(for platform: UsagePlatform) -> [AccountProfileEntry] {
        let entries = items[platform.rawValue] ?? []
        return entries.isEmpty ? [.init(id: AccountProfileEntry.legacyID, label: platform.title)] : entries.map {
            var entry = $0
            if entry.isLegacy && entry.label == "原有账号" { entry.label = platform.title }
            return entry
        }
    }
    func active(for platform: UsagePlatform) -> AccountProfileEntry {
        let entries = entries(for: platform)
        return entries.first { $0.id == selection[platform.rawValue] } ?? entries[0]
    }
    mutating func select(_ id: UUID, for platform: UsagePlatform) {
        guard entries(for: platform).contains(where: { $0.id == id }) else { return }
        selection[platform.rawValue] = id
    }
    @discardableResult mutating func add(platform: UsagePlatform, label: String) -> AccountProfileEntry {
        let cleaned = Self.cleanLabel(label)
        let entry = AccountProfileEntry(id: UUID(), label: cleaned.isEmpty ? nextLabel(for: platform) : cleaned)
        items[platform.rawValue] = entries(for: platform) + [entry]; selection[platform.rawValue] = entry.id
        return entry
    }
    mutating func rename(_ id: UUID, platform: UsagePlatform, label: String) {
        var entries = entries(for: platform)
        if let index = entries.firstIndex(where: { $0.id == id }) {
            let cleaned = Self.cleanLabel(label)
            if !cleaned.isEmpty { entries[index].label = cleaned }
        }
        items[platform.rawValue] = entries
    }
    mutating func identify(_ id: UUID, platform: UsagePlatform, identity: String?) {
        var entries = entries(for: platform)
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].identity = identity }
        items[platform.rawValue] = entries
    }
    mutating func remove(_ id: UUID, platform: UsagePlatform) {
        let remaining = entries(for: platform).filter { $0.id != id }
        items[platform.rawValue] = remaining
        if selection[platform.rawValue] == id { selection[platform.rawValue] = remaining.first?.id }
    }
    mutating func reset(_ platform: UsagePlatform) { items.removeValue(forKey: platform.rawValue); selection.removeValue(forKey: platform.rawValue) }
    func store(for platform: UsagePlatform, root: SessionStore) -> SessionStore { store(for: platform, entry: active(for: platform), root: root) }
    func store(for platform: UsagePlatform, entry: AccountProfileEntry, root: SessionStore) -> SessionStore {
        entry.isLegacy ? root : SessionStore(directory: root.directory.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(platform.rawValue, isDirectory: true).appendingPathComponent(entry.id.uuidString, isDirectory: true))
    }
    func nextLabel(for platform: UsagePlatform) -> String {
        let names = Set(entries(for: platform).map(\.label))
        if !names.contains(platform.title) { return platform.title }
        let suffixes = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        var index = 0
        while names.contains(platform.title + (suffixes[safe: index] ?? String(index + 1))) { index += 1 }
        return platform.title + (suffixes[safe: index] ?? String(index + 1))
    }
    private static func cleanLabel(_ label: String) -> String {
        let result = String(label.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline }.prefix(30))
        return result
    }
}
