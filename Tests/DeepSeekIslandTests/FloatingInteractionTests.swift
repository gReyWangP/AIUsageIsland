import AppKit
import XCTest
import SwiftUI
@testable import DeepSeekIsland
final class FloatingInteractionTests: XCTestCase {
 func testIconsMorphThroughIntermediatePositionsInsteadOfSwitchingStacks() {
  XCTAssertEqual(FloatingStatusFlowLayout.center(index:2,progress:0),CGPoint(x:24,y:124))
  XCTAssertEqual(FloatingStatusFlowLayout.center(index:2,progress:0.5),CGPoint(x:74,y:74))
  XCTAssertEqual(FloatingStatusFlowLayout.center(index:2,progress:1),CGPoint(x:124,y:24))
 }
 func testDockCollapsesAfterLeavingAndRevealsAtEdge() {
  var state=FloatingStatusInteraction()
  let now=Date(timeIntervalSince1970:100)
  state.update(insideBar:false,insideCard:false,docked:true,dragging:false,at:now)
  state.update(insideBar:false,insideCard:false,docked:true,dragging:false,at:now.addingTimeInterval(0.7))
  XCTAssertTrue(state.collapsed)
  state.update(insideBar:true,insideCard:false,docked:true,dragging:false,at:now.addingTimeInterval(0.8))
  XCTAssertFalse(state.collapsed)
 }
 func testCardBridgeAndDraggingPreventCollapseButFreeWindowNeverHides() {
  for flags in [(true,false,true),(false,true,true),(false,false,false)] {
   var state=FloatingStatusInteraction()
   for tick in [0.0,2.0] {
    state.update(insideBar:false,insideCard:flags.0,docked:flags.2,dragging:flags.1,at:Date(timeIntervalSince1970:100+tick))
   }
   XCTAssertFalse(state.collapsed)
  }
 }
 func testCollapsedStripIsAtPhysicalScreenEdgeWithoutLeakingToAdjacentScreen() {
  let screen=CGRect(x:-1200,y:0,width:1200,height:900)
  let expanded=CGRect(x:-1194,y:350,width:62,height:164)
  let left=FloatingStatusLayout.collapsedFrame(expanded:expanded,edge:.left,screen:screen)
  XCTAssertEqual(left.minX,-1200);XCTAssertEqual(left.width,8)
  XCTAssertEqual(left.midY,expanded.midY);XCTAssertTrue(screen.contains(left))
  let right=FloatingStatusLayout.collapsedFrame(expanded:expanded,edge:.right,screen:screen)
  XCTAssertEqual(right.maxX,0);XCTAssertTrue(screen.contains(right))
 }
}

@MainActor
final class FloatingPointerWindowTests: XCTestCase {
 func testTuckedWindowRevealsAndHoverOpensPreviewAcrossAllDockEdges() async throws {
  _ = NSApplication.shared
  let suite=UUID().uuidString, defaults=UserDefaults(suiteName:suite)!
  let root=SessionStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent(suite))
  defer { defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root.directory) }
  let settings=IslandSettings(defaults:defaults)
  settings.floatingStatusEnabled=true;settings.pausesHoverInFullscreen=false
  let model=IslandModel(defaults:defaults,sessionRoot:root)
  model.platformAccounts=PlatformAccounts(enabled:[.chatGPT,.deepSeek,.zhipu])
  model.balance=47;model.accountConnected=true;model.lastUpdated = .now
  model.chatGPTConnected=true;model.chatGPTLastUpdated = .now
  model.chatGPTQuota=ChatGPTQuota(planType:"plus",session:.init(windowSeconds:18000,usedPercent:26,resetAt:nil),weekly:nil,email:nil,accountID:nil,limitReached:false)
  model.zhipuConnected=true;model.zhipuLastUpdated = .now
  model.zhipuQuota=ZhipuQuota(kind:.tokens,level:"Max",fiveHour:.init(usedPercent:82,usedValue:nil,limitValue:nil,nextReset:nil),week:nil)
  let controller=FloatingStatusController(model:model,settings:settings)
  defer { controller.stop() }
  let outside=NSPoint(x:-100000,y:-100000)
  var now=Date.now
  for edge in [FloatingStatusEdge.left,.right,.top] {
   controller.closeDetails()
   settings.floatingStatusPlacement=FloatingStatusPlacement(edge:edge,x:0.35,y:0.35)
   now=now.addingTimeInterval(10)
   controller.update(pointer:outside,at:now)
   let panel=try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is NSHostingView<FloatingStatusView> })
   let host=try XCTUnwrap(panel.contentView as? NSHostingView<FloatingStatusView>)
   controller.update(pointer:outside,at:now.addingTimeInterval(1))
   try await Task.sleep(for:.milliseconds(350))
   if edge == .top { XCTAssertEqual(panel.frame.height,8,accuracy:1) }
   else { XCTAssertEqual(panel.frame.width,8,accuracy:1) }
   XCTAssertTrue(host.rootView.surface.collapsed)
   settings.floatingStatusAlwaysExpanded=true
   controller.update(pointer:outside,at:now.addingTimeInterval(1.01))
   controller.update(pointer:outside,at:now.addingTimeInterval(2))
   try await Task.sleep(for:.milliseconds(350))
   XCTAssertFalse(host.rootView.surface.collapsed,"开启常驻后即使鼠标不在窗口也必须保持展开")
   XCTAssertEqual(settings.floatingStatusPlacement.edge,edge)
   settings.floatingStatusAlwaysExpanded=false
   controller.update(pointer:outside,at:now.addingTimeInterval(2.1))
   controller.update(pointer:outside,at:now.addingTimeInterval(2.8))
   try await Task.sleep(for:.milliseconds(350))
   XCTAssertTrue(host.rootView.surface.collapsed,"关闭常驻后恢复自动隐藏")
   let strip=panel.frame
   controller.update(pointer:NSPoint(x:strip.midX,y:strip.midY),at:now.addingTimeInterval(1.1))
   try await Task.sleep(for:.milliseconds(350))
   XCTAssertFalse(host.rootView.surface.collapsed)
   let stationary=NSPoint(x:strip.midX,y:strip.midY)
   controller.update(pointer:stationary,at:now.addingTimeInterval(1.2))
   controller.update(pointer:stationary,at:now.addingTimeInterval(1.9))
   XCTAssertFalse(host.rootView.surface.collapsed,"鼠标停在原边缘小条位置时必须保持展开，不能反复弹出收起")
   if edge == .top { XCTAssertEqual(panel.frame.height,62,accuracy:1) }
   else { XCTAssertEqual(panel.frame.width,62,accuracy:1) }
   let point=NSPoint(x:panel.frame.midX,y:panel.frame.midY)
   host.rootView.onHover(.chatGPT,true)
   controller.update(pointer:point,at:now.addingTimeInterval(2))
   controller.update(pointer:point,at:now.addingTimeInterval(2.4))
   try await Task.sleep(for:.milliseconds(80))
   let card=try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentViewController is NSHostingController<MenuBarPopoverView> })
   let cardHost=try XCTUnwrap(card.contentViewController as? NSHostingController<MenuBarPopoverView>)
   XCTAssertEqual(cardHost.rootView.source.account.platform,.chatGPT)
   host.rootView.onHover(.chatGPT,false)
   controller.update(pointer:NSPoint(x:card.frame.midX,y:card.frame.midY),at:now.addingTimeInterval(2.5))
   XCTAssertTrue(card.isVisible,"移入详情卡片不能收起")
   controller.update(pointer:outside,at:now.addingTimeInterval(3))
   controller.update(pointer:outside,at:now.addingTimeInterval(3.5))
   XCTAssertFalse(card.isVisible,"离开后关闭悬停预览")
   controller.update(pointer:outside,at:now.addingTimeInterval(4.2))
   try await Task.sleep(for:.milliseconds(350))
   XCTAssertTrue(host.rootView.surface.collapsed)
   let content=try XCTUnwrap(panel.contentView)
   content.layoutSubtreeIfNeeded()
   let bitmap=try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in:content.bounds))
   content.cacheDisplay(in:content.bounds,to:bitmap)
   XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x:0,y:0)).alphaComponent,0.3,"贴边小条的角必须透明，不能是直角黑块")
   XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)).alphaComponent,0.7)
   try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:"/tmp/aiusage-tucked-\(edge.rawValue).png"))
  }
  controller.closeDetails()
  let panel=try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is NSHostingView<FloatingStatusView> })
  now=now.addingTimeInterval(20)
  controller.update(pointer:NSPoint(x:panel.frame.midX,y:panel.frame.midY),at:now)
  try await Task.sleep(for:.milliseconds(350))
  let bounds=try XCTUnwrap(panel.screen).visibleFrame
  for edge in [FloatingStatusEdge.left,.top] {
   let start=NSPoint(x:panel.frame.midX,y:panel.frame.midY)
   controller.drag(to:start,ended:false)
   controller.update(pointer:outside,at:now.addingTimeInterval(2))
   XCTAssertFalse((panel.contentView as! NSHostingView<FloatingStatusView>).rootView.surface.collapsed,"拖动过程中不能收起")
   let finish = edge == .left
       ? NSPoint(x:bounds.minX + panel.frame.width / 2 + 10,y:bounds.midY)
       : NSPoint(x:bounds.midX,y:bounds.maxY - panel.frame.height / 2 - 10)
   let previousPlacement=settings.floatingStatusPlacement
   controller.drag(to:finish,ended:false)
   try await Task.sleep(for:.milliseconds(300))
   let dragHost=try XCTUnwrap(panel.contentView as? NSHostingView<FloatingStatusView>)
   XCTAssertEqual(dragHost.rootView.surface.horizontal,edge == .top,"未松手时就必须切换方向")
   XCTAssertEqual(settings.floatingStatusPlacement,previousPlacement,"拖动预览不能提前保存停靠位置")
   if edge == .top { XCTAssertGreaterThan(panel.frame.width,panel.frame.height) }
   else { XCTAssertGreaterThan(panel.frame.height,panel.frame.width) }
   controller.update(pointer:finish,at:now.addingTimeInterval(2.1))
   XCTAssertEqual(dragHost.rootView.surface.horizontal,edge == .top,"轮询不能覆盖拖动预览方向")
   controller.drag(to:finish,ended:true)
   try await Task.sleep(for:.milliseconds(350))
   XCTAssertEqual(settings.floatingStatusPlacement.edge,edge)
   if edge == .left { XCTAssertEqual(panel.frame.width,62,accuracy:1) }
   else { XCTAssertEqual(panel.frame.height,62,accuracy:1) }
   now=now.addingTimeInterval(10)
  }
 }
}
