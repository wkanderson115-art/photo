import CoreGraphics
import Foundation

var checks = 0
func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { fatalError("FAIL: " + label) }
    print("PASS: " + label)
}
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-6 }

expect(CaptureLayout.isLandscape(CGSize(width: 852, height: 393)), "Wider than tall is landscape")
expect(!CaptureLayout.isLandscape(CGSize(width: 393, height: 852)), "Taller than wide is portrait")
expect(!CaptureLayout.isLandscape(CGSize(width: 500, height: 500)), "A square counts as portrait")

expect(near(CaptureLayout.previewAspect(frameAspect: 0.75, landscape: false), 0.75), "Portrait frame in portrait UI keeps its aspect")
expect(near(CaptureLayout.previewAspect(frameAspect: 4.0 / 3.0, landscape: true), 4.0 / 3.0), "Landscape frame in landscape UI keeps its aspect")
expect(near(CaptureLayout.previewAspect(frameAspect: 0.75, landscape: true), 4.0 / 3.0), "A stale portrait frame is flipped in a landscape UI")
expect(near(CaptureLayout.previewAspect(frameAspect: 4.0 / 3.0, landscape: false), 0.75), "A stale landscape frame is flipped in a portrait UI")
expect(CaptureLayout.previewAspect(frameAspect: 16.0 / 9.0, landscape: true) <= 2, "Landscape aspect is capped at 2")
expect(near(CaptureLayout.previewAspect(frameAspect: .nan, landscape: false), 0.75), "Invalid aspect falls back in portrait")
expect(near(CaptureLayout.previewAspect(frameAspect: 0, landscape: true), 4.0 / 3.0), "Zero aspect falls back in landscape")

let wide = CaptureLayout.fit(aspect: 4.0 / 3.0, in: CGSize(width: 600, height: 300))
expect(near(wide.height, 300) && near(wide.width, 400), "Height-limited landscape preview fits")
let narrow = CaptureLayout.fit(aspect: 4.0 / 3.0, in: CGSize(width: 300, height: 600))
expect(near(narrow.width, 300) && near(narrow.height, 225), "Width-limited preview fits")
expect(CaptureLayout.fit(aspect: 1, in: .zero) == .zero, "An empty container gives an empty preview")

// MARK: - 取景框规划：按真机尺寸断言「不溢出 + 占够面积」
// 安全区与快门条按 iPhone 15 取值：竖屏 393×852（状态栏 59 / 底部 34 / 快门条 100），
// 横屏 852×393（左右 59 / 底部 21）。
func phonePortrait() -> CGSize { CGSize(width: 393, height: 852 - 59 - 34 - 100) }
func phoneLandscape() -> CGSize { CGSize(width: 852 - 59 * 2, height: 393 - 21) }

// 竖屏：控制区实测高度从 V25 的 286 压到 120 之后，取景框占比应过 60%
let tight = CaptureLayout.plan(available: phonePortrait(), landscape: false, aspect: 0.75,
                               topBar: 52, bottomBar: 286)
let compact = CaptureLayout.plan(available: phonePortrait(), landscape: false, aspect: 0.75,
                                 topBar: 52, bottomBar: 120)
expect(tight.overflow == 0, "Portrait tall control strip does not overflow")
expect(compact.overflow == 0, "Portrait compact control strip does not overflow")
expect(compact.preview.height > tight.preview.height, "Compact controls give a taller preview")
expect(compact.fillRatio > 0.60, "Compact controls fill over 60% of the portrait area")
expect(tight.fillRatio < 0.35, "Tall controls leave the preview below 35% (the V25 problem)")

// 横屏：控制浮层不占高度时，取景框应吃掉 45% 以上（4:3 在宽屏里必然左右留黑边）
let landscapeOverlay = CaptureLayout.plan(available: phoneLandscape(), landscape: true, aspect: 4.0 / 3.0,
                                          topBar: 52, bottomBar: 0)
expect(landscapeOverlay.overflow == 0, "Landscape overlay layout does not overflow")
expect(landscapeOverlay.fillRatio > 0.45, "Landscape overlay fills over 45% of the area")
expect(near(landscapeOverlay.preview.height, landscapeOverlay.previewArea.height),
       "Landscape preview is height-limited (system-camera behaviour)")

// 旧版横屏（右侧 250pt 栏 + 快门占高度）会把取景框压到 10% 以下——这就是要改的原因
let oldLandscape = CaptureLayout.plan(available: CGSize(width: 852 - 59 * 2 - 250 - 28,
                                                        height: 393 - 21 - 100),
                                      landscape: true, aspect: 4.0 / 3.0, topBar: 52, bottomBar: 0)
let oldScreenArea = phoneLandscape().width * phoneLandscape().height
let oldFillRelativeToScreen = oldLandscape.preview.width * oldLandscape.preview.height / oldScreenArea
expect(oldFillRelativeToScreen < 0.30, "The old landscape layout wasted the viewfinder (<30%)")

// 边界：空容器 / 非法数值一律不崩，返回 0 与 overflow 0
let emptyPlan = CaptureLayout.plan(available: .zero, landscape: false, aspect: 0.75, topBar: 52, bottomBar: 0)
expect(emptyPlan.preview == .zero && emptyPlan.overflow == 0, "Empty container gives an empty plan")
let nanPlan = CaptureLayout.plan(available: CGSize(width: CGFloat.nan, height: 400), landscape: false,
                                 aspect: CGFloat.nan, topBar: CGFloat.nan, bottomBar: CGFloat.nan)
expect(nanPlan.preview == .zero && nanPlan.fillRatio == 0, "NaN inputs collapse to an empty plan")
print("Layout tests passed: \(checks)")
