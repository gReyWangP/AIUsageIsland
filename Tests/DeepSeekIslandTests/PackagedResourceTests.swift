import Foundation
import XCTest
@testable import DeepSeekIsland

final class PackagedResourceTests: XCTestCase {
    func testInstalledAppUsesContentsResourcesAndNeverFallsBackToBuildDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.resources", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: app))
        // Even when the real development bundle exists, a packaged app with missing resources must not use it.
        XCTAssertNil(IslandResources.packagedBundle(in: bundle))
        let resources = contents.appendingPathComponent("Resources/AIUsageIsland_DeepSeekIsland.bundle")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: resources.appendingPathComponent("marker.txt"))
        let resolved = try XCTUnwrap(IslandResources.packagedBundle(in: bundle))
        XCTAssertEqual(resolved.bundleURL.standardizedFileURL.path, resources.standardizedFileURL.path)
        XCTAssertNotNil(resolved.url(forResource: "marker", withExtension: "txt"))
    }
}
