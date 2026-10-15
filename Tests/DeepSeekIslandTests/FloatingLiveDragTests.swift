import AppKit
import XCTest
@testable import DeepSeekIsland
final class FloatingLiveDragTests: XCTestCase {
 func testChangesOrientationBeforeReleaseAndKeepsGrabPointUnderPointer() {
  let bounds=CGRect(x:0,y:0,width:1200,height:900)
  let now=Date(timeIntervalSince1970:100)
  var drag=FloatingStatusDrag(frame:CGRect(x:6,y:300,width:62,height:164),pointer:CGPoint(x:37,y:382),edge:.left)
  let pointer=CGPoint(x:600,y:880)
  drag.update(pointer:pointer,in:bounds,count:3,at:now)
  XCTAssertEqual(drag.edge,.top)
  let middle=drag.frame(at:now.addingTimeInterval(0.12))
  XCTAssertGreaterThan(middle.width,62);XCTAssertLessThan(middle.width,164)
  XCTAssertEqual(middle.midX,pointer.x,accuracy:0.01)
  XCTAssertEqual(middle.midY,pointer.y,accuracy:0.01)
  let end=drag.frame(at:now.addingTimeInterval(0.3))
  XCTAssertEqual(end.size,CGSize(width:164,height:62))
  drag.update(pointer:CGPoint(x:20,y:450),in:bounds,count:3,at:now.addingTimeInterval(0.4))
  XCTAssertEqual(drag.edge,.left)
  XCTAssertEqual(drag.frame(at:now.addingTimeInterval(0.7)).size,CGSize(width:62,height:164))
 }
 func testTopIntentDoesNotFlickerNearBoundaryAndReversalIsContinuous() {
  let bounds=CGRect(x:-1200,y:0,width:1200,height:900), now=Date(timeIntervalSince1970:100)
  var drag=FloatingStatusDrag(frame:CGRect(x:-1194,y:300,width:62,height:164),pointer:CGPoint(x:-1163,y:382),edge:.left)
  drag.update(pointer:CGPoint(x:-600,y:880),in:bounds,count:3,at:now)
  drag.update(pointer:CGPoint(x:-600,y:835),in:bounds,count:3,at:now.addingTimeInterval(0.1))
  XCTAssertEqual(drag.edge,.top)
  let before=drag.frame(at:now.addingTimeInterval(0.12)).size
  drag.update(pointer:CGPoint(x:-600,y:700),in:bounds,count:3,at:now.addingTimeInterval(0.12))
  XCTAssertEqual(drag.edge,.free)
  XCTAssertEqual(drag.frame(at:now.addingTimeInterval(0.12)).size,before)
 }
}
