# 0.4.29 最终App多项目运行与终端实测

## 范围与夹具

使用最终0.4.29(72)签名Universal App，不使用组件宿主。工作区根目录.multi-project-qa包含first-project／second-project两个独立Git仓库，均有sample.swift和预制运行配置。配置分别传入GW_QA_PROJECT=FIRST／SECOND，工作目录为空（应解析为各自项目根），命令仅打印标记和PWD后sleep1200。无网络／端口／业务依赖。创建基线在.build/multi-project-baseline.json，进程快照在.build/multi-project-processes.json。

## 实际结果

- 第一项目自动读取FIRST QA配置；截图确认中文值50000、重音café42及emoji变量名数字后缀为默认文字色，独立42／12.5／0xFF为数字色。0.4.29最终中文深色颜色复验通过；不是所有语言／主题／词法状态的证明。
- ⌘R启动FIRST，再添加第二项目并⌘R启动SECOND。项目切换日志分别为GW_MULTI_FIRST:<first-project完整路径>与GW_MULTI_SECOND:<second-project完整路径>，配置、环境与cwd没有混用。lsof／ps确认两个独立sleep PID59212和59701。
- 返回FIRST，点其会话停止按钮；FIRST显示已停止，PID59212退出，SECOND PID59701仍存活。停止后台项目没有混入当前日志。
- FIRST中⌘2创建Terminal1；显式输入并回车后输出TERM_FIRST及正确cwd。⌥⌘T新建Terminal2，输出ISOLATION_empty，未继承Terminal1的GW_TERMINAL_MULTI变量。粘贴在zsh bracketed-paste下不会自动执行，均单独回车执行。
- 切SECOND、⌘2，终端为该项目独立Terminal1，输出SECOND_empty及第二项目cwd。read输入中文成功，显示READ_成功。以上通过实际截图确认，SwiftTerm当前AX不提供终端文本内容，未用AX空状态代替输出验收。
- 关闭运行中的SECOND出现“停止运行并关闭项目？”原生确认，明确说明只停止本项目。Esc取消后项目／终端仍在，PID59701仍活；再次关闭并确认“停止并关闭”后SECOND退出。
- 回到FIRST仍有原Terminal1／Terminal2，所选Terminal2保留。选择Terminal1后立即输入命令，输出PRESERVED_FIRST，原环境和输入焦点保持。
- 关闭终端测试前切回运行进程面板，避免回到test1时自动创建新终端；随后关闭FIRST，回test1，未选择两个原业务tabs。

## 清理与局限

核对两仓库HEAD、索引SHA256、Git状态、sample.swift和运行配置SHA256均与创建基线一致；两sleep进程均已退出，lsof对整个测试目录无句柄（含终端shell），随后精确删除.multi-project-qa。没有修改PHP或业务文件，没有启动／停止业务进程，没有向远程发送Git操作。

本轮覆盖2个项目同时运行、同项目2终端／跨项目3终端、停止隔离、关闭取消／确认与清理。没有把它外推为几十个项目压力、输出洪泛、真实交互程序／resize矩阵、全部输入法或全部主题验收。本轮没有修改应用源码，因此没有重复执行已通过的274项全量和打包。
