import Foundation
import Testing

struct LivePreviewKeyPressTests {
  @Test
  func replacementControlOwnsReleaseWithoutRepeatingKeyDown() {
    var keys = LivePreviewKeyPress()
    let old = UUID()
    let current = UUID()
    let events = [
      keys.setPressed(true, code: 3, source: old),
      keys.setPressed(true, code: 3, source: current),
      keys.setPressed(true, code: 3, source: current),
      keys.setPressed(false, code: 3, source: old),
      keys.setPressed(false, code: 3, source: current),
      keys.setPressed(false, code: 3, source: current)
    ]
    #expect(events == [.keyDown(code: 3), nil, nil, nil, .keyUp(code: 3), nil])
  }

  @Test
  func oldControlReleaseCannotEndNewPressAfterFocusChange() {
    var home = LivePreviewKeyPress()
    let old = UUID()
    let current = UUID()
    let firstPress = home.setPressed(true, code: 3, source: old)
    #expect(firstPress == .keyDown(code: 3))
    home.reset()
    let events = [
      home.setPressed(true, code: 3, source: current),
      home.setPressed(false, code: 3, source: old),
      home.setPressed(false, code: 3, source: current)
    ]
    #expect(events == [.keyDown(code: 3), nil, .keyUp(code: 3)])
  }

  @Test
  func differentKeysReleaseIndependently() {
    var keys = LivePreviewKeyPress()
    let source = UUID()
    let events = [
      keys.setPressed(true, code: 4, source: source),
      keys.setPressed(true, code: 26, source: source),
      keys.setPressed(false, code: 4, source: source),
      keys.setPressed(false, code: 26, source: source)
    ]
    #expect(events == [.keyDown(code: 4), .keyDown(code: 26), .keyUp(code: 4), .keyUp(code: 26)])
  }
}
