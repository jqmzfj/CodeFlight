# 0.4.33 文档准备批次优化

## 问题与实现

0.4.32最终App十万行首次打开约1676ms，其中读取完成至准备完成约1297ms。优化编译组件拆分测量和仅对自身探针的1秒sample显示，宽度测量主要停留在CTTypesetterCreateWithAttributedString，包含CJKAddSpace等中英排版工作；单次sample不能解释所有文件／全部UI耗时。

宽度测量继续使用两个同步工作者、Core Text字体回退／Tab／组合字符测量及每批65536 UTF-16跨度上限，仅将每批待测行数从256降为32。保持原生选择、行／字节上限和有界缓存。8行批次对照更慢，未采用；没有预先生成整篇字形或禁用双向文字处理。

## 组件证据

同一优化编译探针直接使用生产源码；每文件每方案3个新进程，按原方案／32行方案交替运行，暖磁盘缓存。原始30条数据见preview-prepare-chunks-0.4.33.json。下表为准备时间中位数：

| 样本 | 原256行批次 | 32行批次 |
| --- | ---: | ---: |
| 200行中英emoji | 8.64ms | 6.34ms |
| 10000行中英emoji | 168.10ms | 115.95ms |
| 100000行中英emoji | 1350.94ms | 1134.75ms |
| 400行混合RTL／组合字／长Unicode行 | 322.20ms | 295.74ms |
| 4MB单行（按现有上限展示） | 65.40ms | 65.81ms |

十万行准备后RSS中位69.47→71.11MiB，结束RSS217.16→215.45MiB，未见整文字体预热那样的额外117MiB开销。阶段RSS不等于峰值；此表不是主App交互延迟。远距离首次TextKit布局仍约390ms，不宣称解决该问题。

Tools/PreviewPerformanceProbe另增显式--prepare-components诊断开关：分开计算无词法索引的准备与单独词法准备，输出prepareComponentsExperiment；不用于上述正式比较，也不加入App。正式探针保持包含词法准备的正常计时。

## 回归与发布

- 12项NativeTextPreviewTests通过，0失败，4.130秒（.build/production-073-preview-tests.log）。宽度对照、RTL隔离字符／组合字／emoji在新批次边界的UTF-16偏移、远距离glyph、原生选择、取消与视口扩大着色已覆盖。
- 官方全量285项通过，0失败，202.497秒（.build/production-073-release.log）。两架构、Universal 2、严格签名、启动smoke、UUID、ZIP及DMG均通过；App、ZIP内程序及release-identity.json的SHA-256一致：d773643d185576e6a8f564f0a81d0d846640a3a7d58becdd22ef7de471b629c0。
- 最终App原生实测：200／10000／100000行首次绘制约128.64／218.78／1274.80ms，缓存复访约121.82／185.62／128.35ms。十万行读取完成至准备完成约968.88ms。每种仅一次首次和复访，非P95、非冷缓存、非合成器呈现延迟；不能据此宣称固定百分比改善。原始记录main-preview-trace-0.4.33.jsonl保留前6条对照测量及后续复验打开记录。AX查询可能干扰内存，生命周期峰值不能归因于单文件。
- 中文浅色原生复验：搜索value50000定位第50001行、value99999定位第100000行，截图检查行号、关键词／字符串颜色及末行均可见；混合阿拉伯文／希伯来文／组合字符／家庭emoji／长Unicode行字体回退和横向滚动布局已观察。没有改动主题偏好，不能将这组观察外推为全部视觉矩阵。
- 专用夹具仅位于工作区根目录.preview-prepare-qa。关闭项目返回test1，退出记录进程；按.build/preview-prepare-baseline.json核对HEAD、索引、状态和五个文件SHA-256均不变，lsof无句柄后精确删除。正常App已重新启动，中文、侧栏285／运行250保留；未选中业务项目或修改PHP。

整体目标仍未完成。
