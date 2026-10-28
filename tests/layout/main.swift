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
expect(near(CaptureLayout.previewAspect(frameAspect: 16.0 / 9.0, landscape: true), 4.0 / 3.0), "A transient video aspect never changes the 4:3 still frame")
expect(near(CaptureLayout.previewAspect(frameAspect: .nan, landscape: false), 0.75), "Invalid aspect falls back in portrait")
expect(near(CaptureLayout.previewAspect(frameAspect: 0, landscape: true), 4.0 / 3.0), "Zero aspect falls back in landscape")
expect(near(CaptureLayout.photoAspect(landscape: true), 4.0 / 3.0), "Landscape stills are 4:3")
expect(near(CaptureLayout.photoAspect(landscape: false), 3.0 / 4.0), "Portrait stills are 3:4")
expect(CaptureLayout.isLandscape(rotationAngle: 0), "0 degrees is landscape")
expect(CaptureLayout.isLandscape(rotationAngle: 180), "180 degrees is landscape")
expect(!CaptureLayout.isLandscape(rotationAngle: 90), "90 degrees is portrait")
expect(!CaptureLayout.isLandscape(rotationAngle: 270), "270 degrees is portrait")
expect(near(CaptureLayout.normalizedRotationAngle(359), 0), "359 degrees settles to 0")
expect(near(CaptureLayout.normalizedRotationAngle(181), 180), "181 degrees settles to 180")

let wide = CaptureLayout.fit(aspect: 4.0 / 3.0, in: CGSize(width: 600, height: 300))
expect(near(wide.height, 300) && near(wide.width, 400), "Height-limited landscape preview fits")
let narrow = CaptureLayout.fit(aspect: 4.0 / 3.0, in: CGSize(width: 300, height: 600))
expect(near(narrow.width, 300) && near(narrow.height, 225), "Width-limited preview fits")
expect(CaptureLayout.fit(aspect: 1, in: .zero) == .zero, "An empty container gives an empty preview")
print("Layout tests passed: \(checks)")
