# 0.4.32 终端基础辅助功能

## 问题与实现

前几轮原生实测中SwiftTerm终端不出现在AX树内，其上游AccessibilityService为空实现。应用层新增WorkbenchTerminalView子类，保留SwiftTerm原生键盘／IME／选择／PTY路径，提供可聚焦textArea、会话标签、当前可见屏幕文本和UTF-16行／范围查询。

读取使用SwiftTerm持锁复制的visibleRowsText，不读取内部可变Terminal、不导出2000行历史，也不保留额外历史副本。只在AX查询时复制屏幕，无后台轮询；VoiceOver启用且窗口可见时对输出／滚动通知150ms合并。输出值不允许AX直接改写，输入仍通过聚焦后键盘完成。语言／会话标题变化可更新标签，不重启会话。

## 当前验证

- swift build通过（.build/production-072-build.log）。
- 8项终端专项通过，0失败，5.592秒（.build/production-072-terminal-tests.log）：新增3项覆盖中文／emoji／组合字符UTF-16与非法范围、2000行滚动容量中仅当前屏幕、会话隔离、备用屏幕切换、原生焦点、语言标签不清空内容；既有5项覆盖真实PTY、cwd、中文read、Ctrl-C、隔离和退出清理。
- 官方发布脚本全量285项通过，0失败，199.394秒（.build/production-072-release.log）。两架构、Universal 2、严格签名、启动smoke、UUID身份、ZIP及DMG验证均通过。ZIP内程序、最终App及release-identity.json的SHA-256一致：bdaa3ebb27d4bcfabd068e57fec8a6831a9a9dc0b5928f57a3dd67dcc208aa74。
- 最终App原生实测：终端以text entry area出现，可读取当前屏幕；printf输出AX_中文🙂，read回读READ_中文输入🙂；第二会话独立显示SECOND_isolated，切回第一会话内容保留；点击预览再点击终端后执行FOCUS_ok成功。中英切换即时更新标签、Esc关闭设置，终端内容和会话保留。
- 未打开VoiceOver，不宣称完成真实语音／全键盘辅助功能验收；中文验证使用Unicode粘贴，真实中文输入法候选／组合仍待验收。
- 手工夹具仅位于工作区根目录.terminal-accessibility-qa，HEAD／索引／状态／README字节基线位于.build/terminal-accessibility-baseline.json。
- 测试后关闭两个终端及临时项目，返回test1，恢复中文／深色／纯色、侧栏285与运行进程250。核对夹具HEAD／索引／状态／README字节不变且lsof无打开句柄后精确删除。没有选中或修改业务项目。
