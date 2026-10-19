import SwiftUI

/// 取景辅助层：三分线、主体框、水平线、水平提示。本身不接收点击（点击交给预览层做对焦）。
struct CompositionOverlay: View {
    let subject: SubjectInfo
    @ObservedObject var motion: MotionService
    let scene: String
    let showGrid: Bool
    let horizonAngle: Double
    let framingHint: String
    let frameAspectRatio: CGFloat

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

                Circle()
                    .stroke(.white.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 54, height: 54)
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))

                if scene == "建筑" || scene == "海边" || scene == "风景" || scene == "日落" {
                    Rectangle()
                        .stroke(abs(horizonAngle) < 0.05 ? Color.green.opacity(0.7) : Color.orange, lineWidth: 2)
                        .frame(width: geo.size.width * 0.72, height: 1)
                        .rotationEffect(.radians(horizonAngle))
                        .offset(y: -geo.size.height * 0.03)
                }

                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: motion.isLevel ? "checkmark.circle.fill" : "rotate.left")
                        Text(motion.isLevel ? "水平 · \(framingHint)" : "请校平 · \(framingHint)")
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.5))
                    .clipShape(Capsule())
                    .padding(.bottom, 150)
                }

                if subject.rect != .zero {
                    let rect = subject.rect
                    let aspect = max(0.01, frameAspectRatio)
                    let imageWidth = max(geo.size.width, geo.size.height * aspect)
                    let imageHeight = imageWidth / aspect
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.cyan, lineWidth: 2)
                        .frame(width: rect.width * imageWidth, height: rect.height * imageHeight)
                        .position(x: rect.midX * imageWidth + (geo.size.width - imageWidth) / 2,
                                  y: (1 - rect.midY) * imageHeight + (geo.size.height - imageHeight) / 2)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}
