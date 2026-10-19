# 户外拍照助手 · 整理修复版

原生 SwiftUI iPhone 相机项目，最低 iOS 17.6，构建脚本要求 Xcode 26+。
应用仅使用系统框架，无第三方运行依赖。

**当前交付状态：已修改源码并通过静态检查，未完成 Xcode 编译、签名或 iPhone 实机验证，没有生成 IPA。**
当前执行环境是 Debian Linux，没有 Apple SDK、Xcode 或可用远程 macOS 构建账号。

## 目录

- `OutdoorPhotoAssistant/`：18 个 Swift 文件、权限配置、隐私清单、图标。
- `OutdoorPhotoAssistant.xcodeproj/`：Xcode 工程与共享 scheme。
- `scripts/`：静态校验、工程生成、图标生成、Debug/Release 构建脚本。
- `tests/main.swift`：使用真实 SmartShutterEngine 源码的决策测试，供 macOS CI 执行。
- `.github/workflows/ios-unsigned-build.yml`：静态检查、决策测试、双配置编译、未签名 IPA 打包。
- `reports/`：本次修复说明与实际检查日志。
- `docs/original/`：输入包附带的历史文档和旧验证日志，不代表本次验证结果。

## 本地静态检查

```bash
python -m pip install -r scripts/requirements-check.txt
python scripts/verify.py
python scripts/check_swift.py OutdoorPhotoAssistant
```

这些检查解析 Swift 语法、工程结构、资源与配置，不会进行 Swift 类型检查或 iOS 编译。

## 在 iPhone 上安装

有 Mac 时，用 Xcode 26+ 打开 `OutdoorPhotoAssistant.xcodeproj`，选择 iPhone，
在 Signing & Capabilities 选择自己的 Apple 开发 Team，使用唯一 Bundle Identifier，点击 Run。
iPhone 需按 Xcode 提示启用开发者模式并信任开发者。签名凭据应留在自己的 Mac 上。

也可以将本目录的内容作为 GitHub 仓库根目录上传（必须包含隐藏的 `.github` 目录），
在 Actions 中运行 `iOS Build (unsigned IPA)`。成功后下载 `OutdoorPhotoAssistant-unsigned-ipa`。
这是待签名的构建产物，必须经自己的 Apple ID/开发者证书签名后才能安装；不能直接在 iPhone 上点开安装。

在已配置的 Mac 上执行 `bash scripts/build_unsigned_ipa.sh` 可构建 Debug、Release 并打包未签名 IPA。
脚本会在缺少 macOS/Xcode/iOS 26 SDK 时明确退出，不会生成伪装的安装包。

本次问题、修复与未验证项详见 [修复报告](reports/REPAIR_REPORT.md)。
