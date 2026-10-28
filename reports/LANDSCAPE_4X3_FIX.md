# 横拍 4:3 修复与核对

目标：手机横放时，界面、相机输出、拍后本地成片和图库保存都保持横向 4:3，成片像素宽度大于高度。

## 本次修复

1. `CaptureLayout` 将照片取景固定为横向 4:3、竖向 3:4，不再让临时的 16:9 分析帧改变照片画幅。
2. `CameraService` 使用 `AVCaptureDevice.RotationCoordinator`，将稳定的 0/90/180/270 度方向同时写入照片输出、分析输出和预览层。
3. 相机切换失败恢复旧镜头时，重新安装方向协调器，避免恢复后锁回竖拍。
4. `CapturedPhoto.displayAspect` 根据原片像素和 EXIF 方向计算实际显示宽高。
5. 拍后渲染使用 `shot.displayAspect`，修复原先始终使用竖屏 `0.75` 导致横图被裁成竖图的问题。
6. 横屏取景显示“横拍 4:3 · 成片宽于高”，保存成功显示“横拍 4:3 已保存到图库”。

## 数据链路

横放手机 → RotationCoordinator 得到 0°/180° → PhotoOutput 写入正确方向 → `fileDataRepresentation()` 保留原片和 EXIF → `displayAspect > 1` → Core Image 先摆正像素再按实际比例裁切 → 本地成片宽度大于高度 → 原片与成片分别写入 App 图库。

## 已执行检查

- Xcode 工程对象、Sources/Resources、Scheme、Info.plist、隐私清单：通过。
- 58 个 Swift 文件 Tree-sitter 语法解析：通过。
- 横拍跨文件专项检查：通过。
- 当前 Linux 环境没有 Xcode/Swift 编译器，仍需云端 Xcode 编译和 iPhone 横放实拍作为硬件验收。

## 真机验收

1. 进入拍摄页，将手机向左、向右各横放一次。
2. 取景框应显示“横拍 4:3 · 成片宽于高”。
3. 两个方向各拍一张，保存提示应为“横拍 4:3 已保存到图库”。
4. 在 App 图库和系统相册分别打开原片与本地成片，四张都应横向显示，像素宽度大于高度，文字和人物方向朝上。
