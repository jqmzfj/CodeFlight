# 0.4.7 验证记录

2026-10-26，macOS 本地验证，构建50。

- 完整235项测试通过，0失败：`.build/production-047-full-tests.log`。覆盖分支错误重试、Stash Git操作、共享草稿保护、退出保护、终端清理和既有预览回归。随后补上原生边缘最小尺寸保护，9项相关回归通过：`.build/production-047-resize-tests.log`；没有把前一轮完整测试声称为最后一次源码的完整重跑。
- 独立原生宿主复用生产模型、分支和Stash视图，最终使用真实生产缩放组件编译。Stash鼠标拖动从620×400扩大到700×460，中文输入保留；方向键和辅助功能增减可用，下限保持620×400。中文浅色与英文深色最低尺寸下所有操作可见。
- 分支英文深色420×260下正文滚动、错误完整可读、底部操作固定；创建失败保留名称；Esc触发未保存保护。此前同宿主已验证取消退出保留草稿、成功创建分支、无修改的重命名禁用提交、Stash成功后清除脏状态以及Git繁忙期间禁用输入和操作。
- 窗口仅配置自身sheet，不更改全局NSWindow样式。拖动以NSEvent的窗口坐标转换到屏幕坐标，不依赖全局指针位置。尚未覆盖多屏和不同缩放比例矩阵；最低高度时分支诊断可能需要手动滚动。
- 专用宿主已退出，工作区根目录`.git-sheets-qa`已删除。实际旧版App另验证终端命令、中文read交互、多会话和工作目录；没有修改业务PHP或选中业务项目。
- 完整App的首次Release复核发现，SwiftUI会在原生边缘拖动中替换最小尺寸约束，导致620×540的Stash缩到420×140、裁切内容。增加仅属于当前sheet的尺寸通知保护；后续Debug完整App重复同一拖动，实际保持620×400且所有操作可见。分支Release中鼠标缩到420×260、保留输入与Esc放弃保护已验证；空Stash状态正确禁用应用、丢弃与保存。

- 最后一次源码的arm64／x86_64 Release均通过且无编译警告；通用二进制、严格ad-hoc签名和启动smoke通过。日志：`.build/production-047-arm.log`、`.build/production-047-intel.log`、`.build/production-047-smoke.log`。
- 最终Universal 2 App在test1再次从原生边缘缩小Stash，实际保持620×400，标题／输入／底部选项均可见。关闭弹窗并恢复文件导航；未提交分支草稿，也未修改test1仓库内容。
- `CodeFlight.app`及`release/CodeFlight-macOS.zip`、`release/CodeFlight-macOS.dmg`已更新。ZIP完整性校验通过，内部版本0.4.7（50）与可执行文件SHA-256匹配最终App。DMG校验日志：`.build/production-047-dmg-verify.log`。

整体仍按`PRODUCTION-READINESS.md`推进，不能将本轮检查视为所有生产质量要求已完成。
