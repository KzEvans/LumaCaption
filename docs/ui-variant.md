# Windows Material 3 分支

本分支：`codex/windows-material3`。共享开发基线：`main`。macOS 界面分支：`codex/mac-liquid-glass`。

采用 Material 3 的颜色角色、NavigationRail、选中指示器、圆角按钮、Filled Tonal 次要操作、Surface Container 卡片，以及 Segoe UI 字体。宽窗口显示展开导航，窄窗口保留图标和标签；历史、设置放在导航底部。所有六个页面继续使用同一识别、翻译、模型和存储逻辑。

配色通过 ColorScheme 生成明暗两套主题，组件使用 primary/onPrimary、secondaryContainer/onSecondaryContainer 和 surface/onSurface 等配对角色，不将 macOS 玻璃效果带入 Windows 页面。

参考：[Material 3 颜色系统](https://m3.material.io/styles/color/the-color-system)、[布局](https://m3.material.io/foundations/layout/canonical-examples/overview)、[Flutter NavigationRail](https://api.flutter.dev/flutter/material/NavigationRail-class.html)。

验证范围：在当前 macOS 主机运行 Flutter 组件测试和 Dart 分析，覆盖所有页面、桌面最小尺寸、明暗主题和 125% 文字缩放。Windows 原生编译、安装和实际显示仍需在 Windows 主机验证；本机没有 Windows SDK，不能据此声称 Windows 安装包验收完成。

切换：`git switch codex/windows-material3`。在 Windows 中运行 `scripts/build_windows.ps1` 生成该分支的安装包。
