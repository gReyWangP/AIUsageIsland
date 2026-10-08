import XCTest
@testable import DeepSeekIsland

final class ApplicationInstanceLockTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testSecondOwnerIsRejectedUntilFirstOwnerReleases() throws {
        let root = directory()
        var first: ApplicationInstanceLock? = try .init(directory: root)
        XCTAssertThrowsError(try ApplicationInstanceLock(directory: root)) {
            XCTAssertEqual($0 as? ApplicationInstanceLock.Failure, .alreadyRunning)
        }
        XCTAssertNotNil(first)
        first = nil
        let second = try ApplicationInstanceLock(directory: root)
        withExtendedLifetime(second) {}
    }
    func testStaleFileDoesNotPreventNextLaunchAndNeverContainsCredentials() throws {
        let root = directory()
        do { let lock = try ApplicationInstanceLock(directory: root); withExtendedLifetime(lock) {} }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)).count, 0)
        let lock = try ApplicationInstanceLock(directory: root)
        withExtendedLifetime(lock) {}
    }
    func testDifferentDataDirectoriesAreIndependent() throws {
        let first = try ApplicationInstanceLock(directory: directory())
        let second = try ApplicationInstanceLock(directory: directory())
        withExtendedLifetime((first, second)) {}
    }
    func testSymlinkDirectoryIsRejected() throws {
        let actual = directory(), linked = directory()
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
        XCTAssertThrowsError(try ApplicationInstanceLock(directory: linked))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: actual.path).isEmpty)
    }
}
