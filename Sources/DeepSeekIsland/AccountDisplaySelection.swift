import Foundation

/// Platform and profile together identify an account; legacy UUIDs are shared across platforms.
struct AccountReference: Codable, Hashable, Identifiable {
    let platform: UsagePlatform
    let profileID: UUID
    var id: String {
        profileID == AccountProfileEntry.legacyID ? platform.rawValue : platform.rawValue + ":" + profileID.uuidString
    }
}

struct AccountDisplaySelection: Codable, Equatable {
    static let limit = 4
    private(set) var accounts: [AccountReference]

    init(accounts: [AccountReference] = []) {
        var seen = Set<AccountReference>()
        self.accounts = Array(accounts.filter { seen.insert($0).inserted }.prefix(Self.limit))
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(accounts: try values.decode([AccountReference].self, forKey: .accounts))
    }
    @discardableResult mutating func setVisible(_ account: AccountReference, _ visible: Bool) -> Bool {
        if !visible { accounts.removeAll { $0 == account }; return true }
        if accounts.contains(account) { return true }
        guard accounts.count < Self.limit else { return false }
        accounts.append(account)
        return true
    }
    mutating func move(_ account: AccountReference, by offset: Int) {
        guard let index = accounts.firstIndex(of: account), accounts.indices.contains(index + offset) else { return }
        accounts.swapAt(index, index + offset)
    }
    func validated(against available: Set<AccountReference>) -> Self {
        Self(accounts: accounts.filter { available.contains($0) })
    }
}
