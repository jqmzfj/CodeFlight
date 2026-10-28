# 0.4.10 预览准备性能

2026-10-26。当前生产预览源码参与优化编译，使用同一脚本、本轮前后各3次独立进程测量；非冷缓存，非真实UI输入延迟或内存峰值。

| 样本 | 准备基线 | 准备优化后 | 准备后RSS 基线→优化后 |
| --- | --- | --- | --- |
| 十万展示行（12万源行，中英／emoji） | 2078.72ms | 1054.28ms | 67.09→67.45MB |
| 一万行 | 203.41ms | 134.22ms | 34.73→36.28MB |
| 4MB单行 | 273.40ms | 64.68ms | 40.73→36.91MB |
| 200行 | 6.40ms | 6.23ms | 31.55→31.58MB |

- 普通LF文件快速跳过四次Foundation换行替换；含CR或Unicode分隔符可能的字节仍走精确规范化路径。
- 中文／emoji／Tab等行保持Core Text精确测量，最多两个同步worker，仍按256行／65536个UTF-16单元分块释放；不建立全项目索引。每个worker独享typesetter和段落样式，最终最大宽度用锁合并。任务取消按块检查，UnsafeCurrentTask严格限制在withUnsafeCurrentTask作用域内，返回前等待worker完成。
- 十万行中段首次绘制基线441.08ms、优化后410.28ms，末尾12.19→12.70ms；不是本轮主要优化点。跳转后RSS205.44→211.69MB，仍需继续优化，不作为完整轻量目标已达标证明。
- 10项针对预览回归通过：中文／emoji／Tab宽度与独立Core Text对照、块边界与长行、非连续布局及跨行选择、未排版全文复制、尺寸改变后的着色、并行多文档隔离、取消结果、CRLF及Unicode换行偏移。
- 原始数据：`docs/preview-performance-0.4.10.json`；日志`.build/production-050-preview-{baseline,parallel,final,tests}.log`。parallel是中间实验结果，final是最终测量。

- 完整240项测试通过，0失败：`.build/production-050-full-tests.log`。包含本轮新增并行准备与取消测试。

- arm64／Intel Release构建通过，无编译warning／error；Universal 2、严格ad-hoc签名及启动smoke通过。DMG checksum、ZIP完整性、0.4.10（53）版本及ZIP二进制SHA256一致性通过。日志`.build/production-050-{arm,intel,smoke,dmg,dmg-verify}.log`。
- 最终Universal App实际打开根目录`.preview-final-qa`：十万展示行末尾及行号、中文／emoji及语法颜色、⌘↑／⌘↓首尾跳转、Shift跨行选择正确；切换小文件后滚动／选择复位、显示3行；4MB单行正常有界预览且显示每行前32KB提示。没有将自动化工具延迟当作真实输入延迟量测。
- 已关闭夹具项目，未打开夹具终端或运行配置；确认三个夹具文件内容与生成时逐字一致后，精确删除`.preview-final-qa`。App恢复test1，未改动业务PHP或运行业务进程。
