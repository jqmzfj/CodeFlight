# 0.4.44 VoiceOver 装饰图标语义修正

## 调整

- 顶部项目标题旁的文件夹图标仅用于视觉提示。此前 macOS 辅助功能树将其读成“移动”，干扰项目名称和路径的朗读；现在将其标记为装饰内容并从 VoiceOver 树隐藏。

## 验证

- `scripts/package-release.sh`：305 tests，0 failures；双架构 production build、Universal 2 合并、自动重建 App、签名、runtime smoke、ZIP 和 DMG 校验全部通过。
- App 版本：0.4.44 (87)；Universal 2 架构：`x86_64 arm64`。
- 最新 SHA-256：
  - App executable：`5d18f2d88abd2ae50cdbd66958cf293ba0ac2bf71fe3bab0598bfa7a54becc04`
  - ZIP：`b7199f181c9f5d027501ce06f0b3541b6124e462bade44606d87a6ed6f9a1e3e`
  - DMG：`2c6dd54f206ce764aa6e73553682a0c6133ca1c52b0b4371716064924dd41462`
- 最终 App 已重启，单一 CodeFlight 进程正常运行；未访问或修改业务项目及 PHP 文件。

## 范围限制

本轮只修正一个已观察到的 VoiceOver 误读，不把它扩大解释成完整辅助功能验收。真实 IME、完整 VoiceOver 键盘导航、触控板手势、窗口主题矩阵、多项目压力和大文件首次跳转仍需继续验证。
