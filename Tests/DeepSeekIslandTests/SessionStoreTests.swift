import Darwin
import Foundation
import XCTest
@testable import DeepSeekIsland

final class SessionStoreTests: XCTestCase {
    func testSessionPersistsWithoutKeychainAndUsesOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        XCTAssertNil(store.readPlatformToken())
        XCTAssertTrue(store.savePlatformToken("browser-grant"))
        XCTAssertEqual(store.readPlatformToken(), "browser-grant")

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("account-grant").path
        )
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        XCTAssertTrue(store.savePlatformToken("updated-grant"))
        XCTAssertEqual(store.readPlatformToken(), "updated-grant")
        XCTAssertTrue(store.deletePlatformToken())
        XCTAssertNil(store.readPlatformToken())
        XCTAssertTrue(store.deletePlatformToken())
    }

    func testSessionReadRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("other")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("account-grant"),
            withDestinationURL: outside
        )
        XCTAssertNil(SessionStore(directory: root).readPlatformToken())
    }
}
