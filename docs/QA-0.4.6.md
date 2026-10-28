# 0.4.6 验证记录

2026-10-26，macOS本地验证，构建49。

- 完整235项测试通过：`.build/production-046-full-tests.log`。随后只扩充测试中的整文件复制断言，9项预览回归再次通过：`.build/production-046-preview-tests.log`。5项终端回归独立通过：`.build/terminal-current-tests.log`。
- 非连续布局保持已知行几何，乱序跳转覆盖空行、Tab、emoji、组合字符和末尾空行；验证远处跳转仍有前文未排版。整文档选择／复制包含未排版段落，使用独立pasteboard，不改用户剪贴板。
- 复用生产组件的原生宿主：十万行首尾／中段跳转与跨行选择；深色搜索高亮；缩小窗口后选择与文字一致；Unicode行／段分隔符显示为独立行；长行横向滚动、固定行号及文件切换复位。行号不再画到工具栏上。
- 最终Universal 2 App实际打开工作区根目录专用夹具，验证十万行中段／末尾绘制、⌘↑／⌘↓首尾定位。关闭夹具终端和项目、退出宿主后删除精确夹具目录，恢复test1。未选中或改动业务PHP项目。
- arm64和x86_64 Release构建通过，无编译警告；Universal 2、严格ad-hoc签名校验、启动smoke通过。日志：`.build/production-046-arm.log`、`.build/production-046-intel.log`、`.build/production-046-smoke.log`。
- 最终构建位于`CodeFlight.app`，分发包位于`release/CodeFlight-macOS.zip`和`release/CodeFlight-macOS.dmg`。

性能数据见`preview-performance-0.4.6.json`，每个样本3个新进程。十万行中段首次跳转绘制中位约487ms、末尾约15ms，准备约2.54秒；准备后RSS67.08MB，跳转后RSS203.95MB。它是组件绘制测量，不能当作冷盘、真实输入延迟、峰值内存或整个应用的内存证明。中段首次布局及资源仍需优化。

整体验收仍按`PRODUCTION-READINESS.md`推进，尚未达到所有窗口、状态和键盘矩阵全部验证完成的条件。
