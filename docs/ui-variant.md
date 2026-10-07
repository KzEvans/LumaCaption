# macOS Liquid Glass 分支

本分支：`codex/mac-liquid-glass`。共享开发基线：`main`。Windows 界面分支：`codex/windows-material3`。两个界面分支从同一基线分别开发。

macOS 26+ 使用系统 `NSGlassEffectView`：侧边导航和主要控制区是 AppKit 原生视图与按钮，通过 Flutter AppKitView 嵌入。玻璃内部的控件放在 contentView 中，使用系统字体、SF Symbols 和系统强调色。字幕、模型、设置等内容区保持实色，避免整页玻璃影响阅读。

13.3–15 运行时回退到 NSVisualEffectView；开启「降低透明度」时改用实色，监听系统显示辅助功能变化。原生控件跟随系统动画及减少动态效果；应用不添加折射模拟或循环装饰动画。明暗设置同步到原生视图和 Flutter 内容。

识别、翻译、模型及存储逻辑沿用共享基线。平台导航通过单独的 design 通道同步页面、忙碌、采集和悬浮窗状态，状态不变时不重复发送。macOS `macos/` Xcode scaffold 仍未集成原生桥接，使用 `scripts/build_macos.sh` 作为已实现入口。

参考：[Apple Liquid Glass 采用指南](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)。本分支使用正式 macOS 26 API，不依赖 effectIsInteractive 等后续测试版接口。

构建要求：macOS 26+ SDK，部署目标 13.3。`scripts/build_macos.sh` 输出 `dist/LumaCaption-0.1.0-macos-arm64-liquid-glass.dmg`，保留先前基线 DMG。GitHub macOS runner 必须配置含上述 SDK 的 Xcode；云端构建尚未运行。

验证：Dart 分析、明暗主题、1120×800 / 860×650、125% 文字缩放的全部内容页组件测试；原生 Swift 编译和实际测试应用检查。普通组件测试使用 Flutter 导航替身，因此不代表原生玻璃绘制验收；实际 AppKit 材质类型与控件连接另由运行应用检查。

切换：`git switch codex/mac-liquid-glass` 或 `git switch codex/windows-material3`。
