import Foundation

enum ApplicationVersion {
    static var version: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
    static var build: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
    static var userAgent: String { "AIUsageIsland/" + (version ?? "development") }
}
