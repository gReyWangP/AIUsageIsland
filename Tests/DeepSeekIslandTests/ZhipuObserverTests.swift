import JavaScriptCore
import XCTest
@testable import DeepSeekIsland

@MainActor
final class ZhipuObserverTests: XCTestCase {
    private func context(identity: String?) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail(error?.toString() ?? "JavaScript error") }
        context.evaluateScript(#"""
        var window = this;
        var reports = [], timers = [], sends = 0;
        var location = { href: 'https://bigmodel.cn/coding-plan/personal/usage' };
        function URL(value) { this.hostname = 'bigmodel.cn'; this.pathname = value; }
        var VueInstance = { $store: { state: { User: { userInfo: {} } } } };
        var webkit = { messageHandlers: { islandCodingQuota: { postMessage: body => reports.push(JSON.parse(body)) } } };
        function setTimeout(callback) { timers.push(callback); }
        function XMLHttpRequest() { this.responseType = 'text'; }
        XMLHttpRequest.prototype.open = function() {};
        XMLHttpRequest.prototype.addEventListener = function(event, callback) { this.callback = callback; };
        XMLHttpRequest.prototype.send = function() { sends++; this.callback(); };
        function quota() {
          var request = new XMLHttpRequest();
          request.responseText = JSON.stringify({code:200,token:'never-forward-this',data:{limits:[
            {type:'TOKENS_LIMIT',unit:3,percentage:10}, {type:'TOKENS_LIMIT',unit:6,percentage:20}
          ]}});
          request.open('GET','/api/monitor/usage/quota/limit'); request.send();
        }
        """#)
        if let identity { context.setObject(identity, forKeyedSubscript: "fixtureIdentity" as NSString)
            context.evaluateScript("VueInstance.$store.state.User.userInfo.customerNumber = fixtureIdentity;") }
        context.evaluateScript(ZhipuWebSession.observerScript)
        return context
    }
    func testObserverForwardsCustomerIdentityWithoutCredentials() throws {
        let context = try context(identity: "customer-1")
        context.evaluateScript("quota();")
        let json = try XCTUnwrap(context.evaluateScript("JSON.stringify(reports[0])")?.toString())
        XCTAssertFalse(json.contains("never-forward-this"))
        let parsed = try ZhipuQuotaParser.parse(Data(json.utf8))
        XCTAssertEqual(parsed.accountIdentity, "customer-1")
        XCTAssertEqual(parsed.fiveHour.usedPercent, 10)
    }
    func testLateIdentityIsForwardedOnceWithoutAnotherQuotaRequest() throws {
        let context = try context(identity: nil)
        context.evaluateScript("quota(); VueInstance.$store.state.User.userInfo.customerNumber = 'late-customer'; timers.shift()();")
        XCTAssertEqual(context.evaluateScript("reports.length")?.toInt32(), 2)
        XCTAssertEqual(context.evaluateScript("sends")?.toInt32(), 1)
        let json = try XCTUnwrap(context.evaluateScript("JSON.stringify(reports[1])")?.toString())
        XCTAssertEqual(try ZhipuQuotaParser.parse(Data(json.utf8)).accountIdentity, "late-customer")
        XCTAssertEqual(context.evaluateScript("timers.length")?.toInt32(), 0)
    }
}
