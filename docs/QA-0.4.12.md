# 0.4.12 多项目运行隔离

- 未识别项目的快捷命令默认留空，移除写死的`pnpm dev`。检测到运行配置时仍显示配置命令。
- 未执行快捷命令按项目ID保存在当前应用会话中；切换项目和恢复运行配置选择不覆盖草稿，显式选择运行配置仍应用该配置命令。关闭项目释放草稿，关闭最后一个项目清空输入。草稿不写入项目磁盘文件。
- 指定后台项目启动时从目标项目读取配置、命令、工作目录和环境变量，不再借用当前项目信息。
- 新增测试覆盖双项目草稿往返与关闭、磁盘配置恢复保留草稿、真实后台子进程的命令／目录／环境隔离。完整243项回归通过，日志`.build/production-052-full-tests.log`。
- 终端复核：当前0.4.11应用中test1的命令执行、工作目录、中文read输入、独立会话环境、Ctrl+C中断和切换保留输出已实测；5项TerminalSessionTests通过。该证据不等同于0.4.12最终包复核。

- 最终Universal App实测：first加载保存的配置命令；second无配置时输入为空且运行禁用；分别编辑first-unsent／second-unsent后反复切换，草稿独立保留，first顶部仍保持QA saved配置。second回车运行仅输出second-unsent；结束后关闭second恢复first草稿，关闭first恢复test1空输入。
- arm64／Intel Release通过，Universal 2严格ad-hoc签名、启动smoke、ZIP完整性、版本0.4.12（55）与二进制SHA256一致性、DMG checksum通过。日志`.build/production-052-{arm,intel,smoke,dmg,dmg-verify}.log`。
- 最终应用已关闭根目录`.run-switch-qa`两个夹具项目并恢复test1；确认无夹具进程、核对文件与配置未变后删除专用夹具。没有选择或修改业务项目、PHP文件或运行业务命令。
