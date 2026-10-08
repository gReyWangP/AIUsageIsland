import JavaScriptCore
import XCTest
@testable import DeepSeekIsland
@MainActor
final class ZhipuAnalysisObserverTests: XCTestCase {
    func testRequestsHistoryInsideSameBrowserAndOnlyForwardsWhitelistedStatistics() throws {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail(error?.toString() ?? "JS error") }
        context.evaluateScript(#"""
        var window=this, reports=[], requests=[], timers=[], location={href:'https://bigmodel.cn/coding-plan/personal/usage'};
        var VueInstance={$store:{state:{User:{userInfo:{customerNumber:'owner-1'}}}}};
        var webkit={messageHandlers:{islandCodingAnalysis:{postMessage:b=>reports.push(JSON.parse(b))}}};
        function URL(value){this.hostname='bigmodel.cn';this.protocol='https:';this.origin='https://bigmodel.cn';this.pathname=value.split('?')[0];}
        function setTimeout(f){timers.push(f);}
        function XMLHttpRequest(){this.headers={};this.callbacks={};}
        XMLHttpRequest.prototype.open=function(method,url){this.url=url;};
        XMLHttpRequest.prototype.setRequestHeader=function(k,v){this.headers[k]=v;};
        XMLHttpRequest.prototype.addEventListener=function(k,f){this.callbacks[k]=f;};
        XMLHttpRequest.prototype.send=function(){requests.push(this);if(this.url.indexOf('model-usage')>=0){this.responseText=JSON.stringify({code:200,token:'response-secret',data:{x_time:['2026-10-01'],tokensUsage:[123],apiKey:'private-key',totalUsage:{totalTokensUsage:123}}});this.callbacks.loadend();}else if(this.callbacks.loadend)this.callbacks.loadend();};
        """#)
        context.evaluateScript(ZhipuWebSession.analysisObserverScript)
        context.evaluateScript(#"""
        var q=new XMLHttpRequest();q.open('GET','/api/monitor/usage/quota/limit');q.setRequestHeader('Authorization','browser-only-secret');q.responseText=JSON.stringify({code:200,data:{limits:[{type:'TOKENS_LIMIT'}]}});q.send();
        """#)
        XCTAssertEqual(context.evaluateScript("requests.length")?.toInt32(),2)
        let url = try XCTUnwrap(context.evaluateScript("requests[1].url")?.toString())
        XCTAssertTrue(url.hasPrefix("https://bigmodel.cn/api/monitor/usage/model-usage?"))
        XCTAssertTrue(url.contains("startTime=")); XCTAssertTrue(url.contains("endTime="))
        XCTAssertEqual(context.evaluateScript("requests[1].headers.Authorization")?.toString(),"browser-only-secret")
        let report = try XCTUnwrap(context.evaluateScript("JSON.stringify(reports[0])")?.toString())
        XCTAssertFalse(report.contains("secret")); XCTAssertFalse(report.contains("private-key"))
        XCTAssertEqual(context.evaluateScript("reports[0].accountIdentity")?.toString(),"owner-1")
        let payload = try XCTUnwrap(context.evaluateScript("JSON.stringify(reports[0].payload)")?.toString())
        XCTAssertEqual(try UsageAnalysisParser.zhipu(Data(payload.utf8)).buckets.first?.tokens,123)
    }
    func testIdentityChangeWhileQuotaIsInFlightNeverLabelsOldAuthAsNewAccount() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        var window=this, reports=[], requests=[], location={href:'https://bigmodel.cn/coding-plan/personal/usage'};
        var VueInstance={$store:{state:{User:{userInfo:{customerNumber:'owner-a'}}}}};
        var webkit={messageHandlers:{islandCodingAnalysis:{postMessage:b=>reports.push(JSON.parse(b))}}};
        function URL(value){this.hostname='bigmodel.cn';this.protocol='https:';this.origin='https://bigmodel.cn';this.pathname=value.split('?')[0];}
        function XMLHttpRequest(){this.headers={};this.callbacks={};}
        XMLHttpRequest.prototype.open=function(method,url){this.url=url;};
        XMLHttpRequest.prototype.setRequestHeader=function(k,v){this.headers[k]=v;};
        XMLHttpRequest.prototype.addEventListener=function(k,f){this.callbacks[k]=f;};
        XMLHttpRequest.prototype.send=function(){requests.push(this);if(this.url.indexOf('quota/limit')>=0){VueInstance.$store.state.User.userInfo.customerNumber='owner-b';this.responseText=JSON.stringify({code:200,data:{limits:[{type:'TOKENS_LIMIT'}]}});this.callbacks.loadend();}};
        """#)
        context.evaluateScript(ZhipuWebSession.analysisObserverScript)
        context.evaluateScript("var q=new XMLHttpRequest();q.open('GET','/api/monitor/usage/quota/limit');q.setRequestHeader('Authorization','owner-a-credential');q.send();")
        XCTAssertEqual(context.evaluateScript("requests.length")?.toInt32(),1,"身份变更后不能复用原账号请求头")
        XCTAssertEqual(context.evaluateScript("reports.length")?.toInt32(),0)
    }

    func testLateIdentityRetriesQuotaUsingCurrentBrowserCredentialBeforeHistory() throws {
        let context=try XCTUnwrap(JSContext())
        context.exceptionHandler = {_,error in XCTFail(error?.toString() ?? "JS error")}
        context.evaluateScript(#"""
        var window=this, reports=[], requests=[], timers=[], location={href:'https://bigmodel.cn/coding-plan/personal/usage'};
        var document={cookie:'bigmodel_token_production=current-browser-token'};
        var localStorage={getItem:key=>''};
        var VueInstance={$store:{state:{User:{userInfo:{customerNumber:null}}}}};
        var webkit={messageHandlers:{islandCodingAnalysis:{postMessage:b=>reports.push(JSON.parse(b))}}};
        function URL(value){this.hostname='bigmodel.cn';this.protocol='https:';this.origin='https://bigmodel.cn';this.pathname=value.replace('https://bigmodel.cn','').split('?')[0];}
        function setTimeout(f){timers.push(f);}
        function XMLHttpRequest(){this.headers={};this.callbacks={};}
        XMLHttpRequest.prototype.open=function(method,url){this.url=url;};
        XMLHttpRequest.prototype.setRequestHeader=function(k,v){this.headers[k]=v;};
        XMLHttpRequest.prototype.addEventListener=function(k,f){this.callbacks[k]=f;};
        XMLHttpRequest.prototype.send=function(){requests.push(this);this.responseText=JSON.stringify(this.url.indexOf('model-usage')>=0 ? {code:200,data:{x_time:['2026-10-01'],tokensUsage:[321]}} : {code:200,data:{limits:[{type:'TOKENS_LIMIT'}]}});if(this.callbacks.loadend)this.callbacks.loadend();};
        """#)
        context.evaluateScript(ZhipuWebSession.analysisObserverScript)
        context.evaluateScript("var q=new XMLHttpRequest();q.open('GET','/api/monitor/usage/quota/limit');q.setRequestHeader('Authorization','obsolete-header');q.send();VueInstance.$store.state.User.userInfo.customerNumber='late-owner';timers.shift()();")
        XCTAssertEqual(context.evaluateScript("requests.length")?.toInt32(),3)
        XCTAssertEqual(context.evaluateScript("requests[1].headers.Authorization")?.toString(),"current-browser-token")
        XCTAssertEqual(context.evaluateScript("requests[2].headers.Authorization")?.toString(),"current-browser-token")
        XCTAssertEqual(context.evaluateScript("reports[0].accountIdentity")?.toString(),"late-owner")
    }

}
