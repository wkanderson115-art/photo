import SwiftUI
import UIKit

struct RootView: View {
    @State private var selectedTab = 0
    var body: some View {
        TabView(selection: $selectedTab) {
            CaptureView(isSelected: selectedTab == 0)
                .tabItem { Label("拍摄", systemImage: "camera.fill") }
                .tag(0)
            GalleryView()
                .tabItem { Label("图库", systemImage: "photo.on.rectangle") }
                .tag(1)
            LearningView()
                .tabItem { Label("学习", systemImage: "book") }
                .tag(2)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
    }
}

struct GalleryView: View {
    @EnvironmentObject var library: PhotoLibraryService

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.accessDenied {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.largeTitle)
                        Text("需要相册权限才能显示最近照片")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 60)
                } else if library.recent.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.largeTitle)
                        Text("还没有照片")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(library.recent.indices), id: \.self) { index in
                            Image(uiImage: self.library.recent[index])
                                .resizable()
                                .scaledToFill()
                                .frame(height: 180)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("图库")
            .onAppear {
                self.library.load()
            }
        }
    }
}

struct LearningView: View {
    private struct Lesson: Identifiable {
        let id: Int
        let title: String
        let detail: String
    }

    private let lessons: [Lesson] = [
        Lesson(id: 0, title: "三分构图", detail: "让主体靠近三分线交点，同时给人物视线或运动方向留空间。"),
        Lesson(id: 1, title: "地平线", detail: "海边、建筑和城市照片先校平；明显倾斜会直接降低构图质量。"),
        Lesson(id: 2, title: "光线", detail: "人物优先侧前方柔光；日落可以逆光，但要保护天空高光。"),
        Lesson(id: 3, title: "镜头", detail: "风景和建筑可尝试 0.5×，人物通常 1×，远处主体再考虑 2×。"),
        Lesson(id: 4, title: "色彩", detail: "先保证自然曝光，再用色谱改变风格；不要用高饱和掩盖错误曝光。"),
        Lesson(id: 5, title: "为什么 AI 让你移动", detail: "AI 会综合主体位置、水平线、亮度和显著区域，目标是减少边缘杂物并建立视觉层次。")
    ]

    var body: some View {
        NavigationStack {
            List(lessons) { lesson in
                VStack(alignment: .leading, spacing: 7) {
                    Text(lesson.title).font(.headline)
                    Text(lesson.detail).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
            }
            .navigationTitle("摄影学习")
        }
    }
}
