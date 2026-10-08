import XCTest
@testable import DeepSeekIsland

final class PlatformManagementTests: XCTestCase {
    func testAddingAlwaysListsAllPlatformsIncludingAlreadyConnectedOnes() {
        var state = PlatformManagementState()
        state.toggle(.adding)
        XCTAssertEqual(state.candidates(in: PlatformAccounts(enabled: [.chatGPT])), [.deepSeek, .zhipu, .chatGPT])
        XCTAssertEqual(state.candidates(in: PlatformAccounts(enabled: Set(UsagePlatform.allCases))), [.deepSeek, .zhipu, .chatGPT])
    }

    func testAddingReturnsChosenPlatformAndClosesList() {
        var state = PlatformManagementState()
        state.toggle(.adding)
        XCTAssertEqual(state.select(.deepSeek, in: PlatformAccounts(enabled: [.chatGPT])), .deepSeek)
        XCTAssertNil(state.mode)
    }

    func testCanAddAnotherAccountToAlreadyEnabledPlatform() {
        var state = PlatformManagementState()
        state.toggle(.adding)
        XCTAssertEqual(state.select(.chatGPT, in: PlatformAccounts(enabled: [.chatGPT])), .chatGPT)
        XCTAssertNil(state.mode)
    }

    func testRemovalRequiresSeparateConfirmation() {
        let accounts = PlatformAccounts(enabled: [.deepSeek, .chatGPT])
        var state = PlatformManagementState()
        state.toggle(.removing)
        XCTAssertEqual(state.candidates(in: accounts), [.deepSeek, .chatGPT])
        XCTAssertNil(state.select(.chatGPT, in: accounts))
        XCTAssertEqual(state.mode, .confirmingRemoval(.chatGPT))
        XCTAssertEqual(state.confirmRemoval(in: accounts), .chatGPT)
        XCTAssertNil(state.confirmRemoval(in: accounts))
        XCTAssertNil(state.mode)
    }

    func testCancellationNeverProducesRemoval() {
        let accounts = PlatformAccounts(enabled: [.chatGPT])
        var state = PlatformManagementState()
        state.toggle(.removing)
        _ = state.select(.chatGPT, in: accounts)
        state.dismiss()
        XCTAssertNil(state.confirmRemoval(in: accounts))
        XCTAssertNil(state.mode)
    }

    func testChangingMenuDismissesPendingConfirmation() {
        let accounts = PlatformAccounts(enabled: [.chatGPT])
        var state = PlatformManagementState()
        state.toggle(.removing)
        _ = state.select(.chatGPT, in: accounts)
        state.toggle(.adding)
        XCTAssertEqual(state.mode, .adding)
        XCTAssertNil(state.confirmRemoval(in: accounts))
        state.toggle(.adding)
        XCTAssertNil(state.mode)
    }

    func testCannotConfirmPlatformThatHasAlreadyBeenRemoved() {
        var state = PlatformManagementState()
        state.toggle(.removing)
        _ = state.select(.chatGPT, in: PlatformAccounts(enabled: [.chatGPT]))
        XCTAssertNil(state.confirmRemoval(in: PlatformAccounts(enabled: [])))
        XCTAssertNil(state.mode)
    }
}
