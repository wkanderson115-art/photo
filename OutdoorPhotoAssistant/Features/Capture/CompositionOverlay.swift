import SwiftUI

/// 可选三分网格；不遮挡对焦操作，不显示常驻分析提示。
struct CompositionOverlay: View {
    let showGrid: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if showGrid {
                    Path { path in
                        for x in [geo.size.width / 3, geo.size.width * 2 / 3] {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geo.size.height))
                        }
                        for y in [geo.size.height / 3, geo.size.height * 2 / 3] {
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                    }
                    .stroke(.white.opacity(0.28), lineWidth: 1)
                }


            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}
