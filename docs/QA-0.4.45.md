# 0.4.45 编辑器标签装饰图标语义修正

## 调整

- 编辑器文件标签中的文件类型图标仅用于视觉提示。此前辅助功能树会将图标单独朗读，随后再次朗读文件名；现在将其标记为装饰内容，保留文件名、完整路径提示和关闭按钮的语义。

## 验证

- `scripts/package-release.sh`：305 tests，0 failures；双架构 production build、Universal 2 合并、自动重建 App、签名、runtime smoke、ZIP 和 DMG 校验全部通过。
- App 版本：0.4.45 (88)；Universal 2 架构：`x86_64 arm64`。
- 最新 SHA-256：
  - App executable：`bff915dbaa387ade3da6d4ee063c7db56f59829fba9e53432227c24d21a4d21e`
  - ZIP：`b61bccc77de2c47702e29a14cfa06910b6ea876677be60300ced17e925390cde`
  - DMG：`6de5e20ba85e5026dbf18df2ae49124a5941990c3bcb5913ba1108273c03e1e3`
- 最终 App 已重启，单一 CodeFlight 进程正常运行；未访问或修改业务项目及 PHP 文件。

## 范围限制

本轮只修正编辑器标签的重复语义，不把它扩大解释成完整辅助功能验收。真实 IME、完整 VoiceOver 键盘导航、触控板手势、窗口主题矩阵、多项目压力和大文件首次跳转仍需继续验证。
