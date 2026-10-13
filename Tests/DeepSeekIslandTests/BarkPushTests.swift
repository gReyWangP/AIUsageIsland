import XCTest
@testable import DeepSeekIsland

@MainActor
final class BarkPushTests: XCTestCase {
    func testManualPushShowsProgressAndPartialResults() async {
        var calls = 0
        var service: BarkPushService!
        service = BarkPushService { request in
            XCTAssertTrue(service.sending)
            XCTAssertTrue(service.manualStatus?.contains("发送中") == true)
            calls += 1
            await Task.yield()
            return (Data("{\"code\":200}".utf8), HTTPURLResponse(url: request.url!, statusCode: calls == 1 ? 200 : 500, httpVersion: nil, headerFields: nil)!)
        }
        await service.sendTest(address: "https://one.example/key\nhttps://two.example/key")
        XCTAssertFalse(service.sending)
        XCTAssertTrue(service.manualStatus?.contains("部分发送成功") == true)
        XCTAssertTrue(service.manualStatus?.contains("成功 1，失败 1") == true)
        XCTAssertTrue(service.manualStatus?.contains("地址 2：发送失败") == true)
        XCTAssertTrue(service.manualStatus?.contains("完成时间") == true)
    }
    func testManualPushShowsFailureAndValidationErrors() async {
        let service = BarkPushService { request in
            (Data("{\"code\":500}".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        await service.sendTest(address: "https://example.com/key")
        XCTAssertTrue(service.manualStatus?.contains("发送失败") == true)
        await service.sendTest(address: "invalid")
        XCTAssertTrue(service.manualStatus?.contains("HTTPS") == true)
        XCTAssertFalse(service.sending)
    }
    func testManualPushShowsAcceptedSuccess() async {
        let service = BarkPushService { request in
            (Data("{\"code\":200}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await service.sendTest(address: "https://example.com/key")
        XCTAssertTrue(service.manualStatus?.contains("发送成功：成功 1") == true)
        XCTAssertTrue(service.manualStatus?.contains("服务器已接受") == true)
    }
    func testResetSummarySeparatesAnnouncementAndResetTimeWithoutInventingReason() {
        let event = OfficialResetAnnouncement(id: "123", resetType: "regular", phase: .reported,
            announcedAt: Date(timeIntervalSince1970: 0), scheduledFor: nil,
            text: "It's done. https://t.co/example", sourceURL: URL(string: "https://x.com/thsottiaux/status/123")!)
        XCTAssertTrue(event.pushSummary.contains("公告时间：1月1日 08:00（北京时间）"))
        XCTAssertTrue(event.pushSummary.contains("重置时间：来源未提供确切发生时间"))
        XCTAssertTrue(event.pushSummary.contains("重置原因：来源未明确说明"))
        XCTAssertFalse(event.pushSummary.contains("t.co"))
        var scheduled = event
        scheduled.phase = .scheduled
        scheduled.scheduledFor = Date(timeIntervalSince1970: 3600)
        XCTAssertTrue(scheduled.pushSummary.contains("预计北京时间 1月1日 09:00"))
    }
    func testCopiedAddressBecomesJSONRequestWithoutKeyInURL() throws {
        let request = try BarkPushService.request(address: " https://example.com/bark/my-device-key/ ", title: "额度偏低", body: "剩余 10%")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/bark/push")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body["device_key"], "my-device-key")
        XCTAssertEqual(body["body"], "剩余 10%")
    }
    func testInvalidAndCredentialBearingAddressesAreRejected() {
        for address in ["", "https://api.day.app", "http://example.com/key", "https://user:secret@example.com/key", "https://example.com/key?secret=1", "https://example.com/push"] {
            XCTAssertThrowsError(try BarkPushService.request(address: address, title: "", body: ""))
        }
    }
    func testHTTPAndBarkApplicationErrorsBothFailWithoutLeakingServerResponse() throws {
        let url = URL(string: "https://example.com/push")!
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        try BarkPushService.validateResponse(Data("{\"code\":200}".utf8), response: ok)
        XCTAssertThrowsError(try BarkPushService.validateResponse(Data("{\"code\":400,\"message\":\"private-key\"}".utf8), response: ok)) { error in
            XCTAssertFalse(error.localizedDescription.contains("private-key"))
        }
        let failed = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try BarkPushService.validateResponse(Data("{\"code\":200}".utf8), response: failed))
    }
    func testMultipleAddressesAreTrimmedDeduplicatedAndMigratedFromSingleAddress() {
        XCTAssertEqual(BarkPushService.addresses(" https://one.example/key \n\nhttps://two.example/key\nhttps://one.example/key"),
            ["https://one.example/key", "https://two.example/key"])
        let name = "BarkMulti." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("https://one.example/key", forKey: "barkPushAddress")
        let settings = IslandSettings(defaults: defaults)
        XCTAssertEqual(settings.barkPushAddresses, ["https://one.example/key"])
        settings.barkPushAddresses += ["https://two.example/key"]
        XCTAssertEqual(IslandSettings(defaults: defaults).barkPushAddresses.count, 2)
    }
    func testConfigurationDefaultsOffAndPersists() {
        let name = "BarkPushTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: defaults)
        XCTAssertFalse(settings.barkPushEnabled)
        XCTAssertEqual(settings.barkPushAddress, "")
        settings.barkPushEnabled = true
        settings.barkPushAddress = "https://example.com/key"
        let restored = IslandSettings(defaults: defaults)
        XCTAssertTrue(restored.barkPushEnabled)
        XCTAssertEqual(restored.barkPushAddress, settings.barkPushAddress)
    }
}
