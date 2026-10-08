import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class IslandButtonLayoutTests: XCTestCase {
    func testPinningDoesNotIncreaseHeaderHeight() throws {
        for scheme in [ColorScheme.light, .dark] {
            func height(pinned: Bool) throws -> Int {
                let header = HStack {
                    Text("用量统计").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    IslandPinButton(pinned: .constant(pinned))
                }
                .font(.system(size: 12))
                .frame(width: 322)
                .environment(\.colorScheme, scheme)
                return try XCTUnwrap(ImageRenderer(content: header).cgImage).height
            }
            XCTAssertEqual(try height(pinned: true), try height(pinned: false),
                           "固定只能改变状态，不能挤压下方滚动区")
        }
    }
}
