# 0.4.31 大跨度跳转采样与排除的预热方案

本轮是诊断与验收补充，没有改变正式预览逻辑或发布版本。正式App仍为0.4.31（74），不是已完成性能优化的新版本。

## 证据

现有优化编译的生产组件探针增加两个显式诊断开关：`--profile-jumps`在安装后发出READY、等待stdin换行，再在多个远距离视口绘制，便于仅采样自己的探针进程；输出profileJumps标记，此时后续middlePaintMS是暖往返，不可当作首次跳转。`--fix-fonts`仅用于对照实验，显式输出fontFixExperiment与额外耗时／RSS，正常基准和正式App不会执行该方案。

专用根目录夹具为100000行中英／emoji源码，3477780字节；各方案新进程3次，暖磁盘缓存，串行执行。原始6条数据见preview-font-fix-experiment-0.4.31.json。基准版本与前一轮源12万行／展示10万行不同，不作跨夹具直接比较。

- 原方案准备中位1278.88ms，中部首绘377.25ms，末尾12.57ms，结束RSS211.95MiB。
- 在安装后对整个NSTextStorage显式fixFontAttribute：额外1021.69ms，随后中部11.84ms，末尾10.11ms，结束RSS328.83MiB；字体准备后的阶段RSS327.14MiB。
- sample仅采自己的probe-profile进程，1秒／1ms间隔；调用栈显示Coordinator.highlight→NSLayoutManager.ensureLayoutForCharacterRange→NSFastFillAllGlyphHolesForCharacterRange→NSGlyphGenerator及NSConcreteTextStorage属性处理，包含CTFont字体回退及属性写入。不能把这1秒采样比例外推为所有输入场景的CPU比例。
- 全文字体预热额外增加约117MiB阶段RSS，且增加约1秒准备，故明确排除；没有为了缩短中部计时将该高内存策略放入正式应用。阶段RSS不等于峰值，组件绘制不等于主App点击或屏幕呈现延迟。

## 实际窗口与清理

- 只读取Xcode当前CodeFlight窗口与截图作为布局参考，未编辑或触发构建。当前原生工具栏、紧凑导航、浅色编辑区对比已观察，不能据此认定全部界面达标。
- 正式App打开本轮专用目录，启动独立终端read。Control-Space实际到达终端为控制字符，未取得真实中文候选窗；系统输入源菜单的CUA读取两次超时。因此本轮没有验证IME，不把粘贴Unicode视作输入法通过，也没有修改系统输入源配置。
- Ctrl-C结束read，关闭专用终端，切回运行工具，关闭测试项目回test1。导航285pt／运行250pt、中文／深色／纯色恢复；夹具文件SHA256与基线不变、lsof无句柄后精确删除。未选择业务项目或修改PHP。

后续仍需研究有界字形／字体准备策略，并验证真实IME和其余窗口视觉／键盘矩阵。整体目标未完成。
