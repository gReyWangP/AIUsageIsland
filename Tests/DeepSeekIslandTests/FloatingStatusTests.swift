import AppKit
import XCTest
import SwiftUI
@testable import DeepSeekIsland
@MainActor final class FloatingStatusTests: XCTestCase {
 func testDraggingNearEdgesSnapsAndReorients() {
  let bounds=CGRect(x:100,y:100,width:1000,height:700)
  let left=FloatingStatusLayout.settle(frame:CGRect(x:110,y:300,width:62,height:164),in:bounds,count:3)
  XCTAssertEqual(left.edge,.left);XCTAssertEqual(left.frame.minX,103)
  let top=FloatingStatusLayout.settle(frame:CGRect(x:400,y:630,width:62,height:164),in:bounds,count:3)
  XCTAssertEqual(top.edge,.top);XCTAssertEqual(top.frame.size,CGSize(width:164,height:62));XCTAssertEqual(top.frame.maxY,797)
  let free=FloatingStatusLayout.settle(frame:CGRect(x:400,y:300,width:62,height:164),in:bounds,count:3)
  XCTAssertEqual(free.edge,.free);XCTAssertEqual(free.frame.minX,400)
 }
 func testRestorationAndGrowingListStayOnScreen() {
  let bounds=CGRect(x:0,y:0,width:800,height:600)
  let frame=FloatingStatusLayout.frame(edge:.right,position:CGPoint(x:1,y:1),in:bounds,count:8)
  XCTAssertEqual(frame.maxX,797);XCTAssertLessThanOrEqual(frame.maxY,597);XCTAssertGreaterThanOrEqual(frame.minY,3)
 }
 func testDisplayModeAndPlacementPersistWithoutChangingLegacyDefault() {
  let name=UUID().uuidString;let defaults=UserDefaults(suiteName:name)!
  defer {defaults.removePersistentDomain(forName:name)}
  let settings=IslandSettings(defaults:defaults)
  XCTAssertFalse(settings.floatingStatusAlwaysExpanded)
  settings.floatingStatusAlwaysExpanded=true
  XCTAssertFalse(settings.floatingStatusEnabled)
  settings.floatingStatusEnabled=true
  settings.floatingStatusPlacement=FloatingStatusPlacement(edge:.right,x:1,y:0.4,displayID:12,displayName:"Studio Display")
  let restored=IslandSettings(defaults:defaults)
  XCTAssertTrue(restored.floatingStatusAlwaysExpanded)
  XCTAssertTrue(restored.floatingStatusEnabled);XCTAssertEqual(restored.floatingStatusPlacement.edge,.right)
  XCTAssertEqual(restored.floatingStatusPlacement.y,0.4)
  XCTAssertEqual(restored.floatingStatusPlacement.displayName,"Studio Display")
 }
 func testLegacyPlacementWithoutDisplayNameStillDecodes() throws {
  let data=#"{"edge":"right","x":1,"y":0.4,"displayID":12}"#.data(using:.utf8)!
  let placement=try JSONDecoder().decode(FloatingStatusPlacement.self,from:data)
  XCTAssertEqual(placement.displayID,12)
  XCTAssertNil(placement.displayName)
 }
 func testControllerSwitchesVisibilityAndOpensDetailsInsideScreen() async throws {
  _ = NSApplication.shared
  let name=UUID().uuidString;let defaults=UserDefaults(suiteName:name)!
  let root=SessionStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent(name))
  defer { defaults.removePersistentDomain(forName:name);try? FileManager.default.removeItem(at:root.directory) }
  let settings=IslandSettings(defaults:defaults)
  settings.pausesHoverInFullscreen=false
  let model=IslandModel(defaults:defaults,sessionRoot:root)
  model.platformAccounts=PlatformAccounts(enabled:[.chatGPT,.deepSeek,.zhipu])
  model.balance=47;model.accountConnected=true;model.lastUpdated = .now
  model.chatGPTConnected=true;model.chatGPTLastUpdated = .now
  model.chatGPTQuota=ChatGPTQuota(planType:"plus",session:.init(windowSeconds:18000,usedPercent:26,resetAt:nil),weekly:nil,email:nil,accountID:nil,limitReached:false)
  model.zhipuConnected=true;model.zhipuLastUpdated = .now
  model.zhipuQuota=ZhipuQuota(kind:.tokens,level:"Max",fiveHour:.init(usedPercent:82,usedValue:nil,limitValue:nil,nextReset:nil),week:nil)
  let controller=FloatingStatusController(model:model,settings:settings)
  defer { controller.stop() }
  settings.floatingStatusEnabled=true
  controller.update()
  let panel=try XCTUnwrap(NSApp.windows.first { $0.contentView is NSHostingView<FloatingStatusView> && $0.isVisible })
  XCTAssertEqual(panel.frame.width,62)
  XCTAssertNotNil(settings.floatingStatusPlacement.displayID)
  let bounds=try XCTUnwrap(panel.screen).visibleFrame
  XCTAssertGreaterThanOrEqual(panel.frame.minX,bounds.minX)
  for edge in [FloatingStatusEdge.left,.right,.top] {
   settings.floatingStatusPlacement=FloatingStatusPlacement(edge:edge,x:0.5,y:0.5)
   controller.update();controller.showDetails()
   try await Task.sleep(for:.milliseconds(100))
   let card=try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentViewController is NSHostingController<MenuBarPopoverView> })
   if edge == .left { XCTAssertGreaterThan(card.frame.minX,panel.frame.maxX) }
   if edge == .right { XCTAssertLessThan(card.frame.maxX,panel.frame.minX) }
   XCTAssertGreaterThanOrEqual(card.frame.minY,bounds.minY)
   XCTAssertLessThanOrEqual(card.frame.maxY,bounds.maxY)
   let content=try XCTUnwrap(panel.contentView)
   content.layoutSubtreeIfNeeded()
   let bitmap=try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in:content.bounds))
   content.cacheDisplay(in:content.bounds,to:bitmap)
   try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:"/tmp/aiusage-floating-status-\(edge.rawValue).png"))
  }
  controller.closeDetails()
  XCTAssertFalse(NSApp.windows.contains { $0.isVisible && $0.contentViewController is NSHostingController<MenuBarPopoverView> })
  controller.toggleDetails()
  XCTAssertTrue(NSApp.windows.contains { $0.isVisible && $0.contentViewController is NSHostingController<MenuBarPopoverView> })
  controller.toggleDetails()
  XCTAssertFalse(NSApp.windows.contains { $0.isVisible && $0.contentViewController is NSHostingController<MenuBarPopoverView> })
  let work=model.accountProfiles.add(platform:.chatGPT,label:"通知账号")
  let workAccount=AccountReference(platform:.chatGPT,profileID:work.id)
  model.focusNotification(.chatGPTFiveHour,account:workAccount)
  controller.showDetails(account:workAccount)
  let targeted=try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentViewController is NSHostingController<MenuBarPopoverView> })
  let targetHost=try XCTUnwrap(targeted.contentViewController as? NSHostingController<MenuBarPopoverView>)
  XCTAssertEqual(targetHost.rootView.source.account,workAccount)
  controller.closeDetails()
  XCTAssertNil(model.notificationDetailAccount)
  XCTAssertNil(model.detailFocus)
  settings.floatingStatusEnabled=false;controller.update()
  XCTAssertFalse(panel.isVisible)
 }
 func testDeepSeekFloatingRingHasSameFootprintAtEveryBalance() {
  for amount in [Decimal(47),Decimal(3),Decimal(string:"0.50")!] {
   let image=MenuBarRenderer.image(platform:.deepSeek,data:.balance(amount:amount,currency:"CNY"),dark:true,balanceAsRing:true)
   XCTAssertEqual(image.size,CGSize(width:20,height:18))
  }
  XCTAssertEqual(UsageReading.balance(amount:5,currency:"CNY").health,.healthy)
  XCTAssertEqual(UsageReading.balance(amount:1,currency:"CNY").health,.warning)
  XCTAssertEqual(UsageReading.balance(amount:Decimal(string:"0.99")!,currency:"CNY").health,.critical)
 }
}
