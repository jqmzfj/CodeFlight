# 0.4.43 主题选择与发布包一致性

## 调整

- 工作台菜单的主题入口改为明确的“跟随系统／浅色／深色”三项选择，当前选项显示勾选状态。
- 保留 `⌘⇧D` 作为浅色／深色快速切换；只有用户明确使用主题菜单选择“跟随系统”时才恢复系统主题，快捷切换后的选择会按用户操作保存。
- 发布脚本在签名和冒烟测试前，始终使用本轮 arm64 与 x86_64 构建合并出的 Universal 二进制重建 `CodeFlight.app`，避免工作区旧 App 被打进新安装包。

## 验证

- `swift test`：305 tests，0 failures。
- `scripts/package-release.sh`：双架构 production build、Universal 2 合并、自动重建 App、签名、runtime smoke、ZIP 和 DMG 校验全部通过。
- App 版本：0.4.43 (86)；Universal 2 架构：`x86_64 arm64`。
- 最新 SHA-256：
  - App executable：`155f13c94f100e51786d2f6e2bc79f9489ac13291c0a5c71d811471d53c6f7f7`
  - ZIP：`77fec897f0f62a09630d132482d3cbf58e8c152ee61c07aa65902329f8de6c03`
  - DMG：`f7fa280d63a12de2dd5616d92993990c79951823a3da6d252202fefe0b9d4155`
- 最终 App 已重启，单一 CodeFlight 进程正常运行；Windows 版本继续暂停。

## 范围限制

本轮没有把主题菜单变更误作完整 Xcode 级验收。真实触控板手势、完整窗口视觉矩阵、真实 IME／VoiceOver、多项目压力和远距离大文件首次跳转仍需后续继续验证。
