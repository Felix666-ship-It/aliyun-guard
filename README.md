# Aliyun Guard

Aliyun Guard 是参考 [10000ge10000/aliyun_monitor](https://github.com/10000ge10000/aliyun_monitor) 的保活规则重新实现的独立版本：查询账号当月 CDT 公网流量和当前 ECS 实例账单，低于流量阈值时确保指定 ECS 运行，达到阈值时停止 ECS，并在每轮检测结束后发送 Telegram 汇总。

新版没有复用原项目的配置目录。CDT、ECS、BSS 账单和 Telegram 分别记录结果；账单权限或 Endpoint 出错会明确写入本轮通知和日志，但不会阻断基于 CDT 流量的开关机判断。

## 主要功能

- 首次安装和日常管理均为中文交互菜单。
- 多账号、多 Region、多 ECS 实例。
- 查询当月实例税前账单，分别支持阿里云中国站、国际站和自定义 BSS Endpoint。
- 默认每轮检测完成都发送 Telegram 汇总；也可改为仅事件或仅错误通知。
- 安装时只读校验 Telegram、AccessKey、CDT、ECS、BSS 权限、Region 和实例 ID。
- 支持立即检测、无动作演练、暂停实例、编辑配置、查看状态和日志。
- 检测进程带文件锁，避免手动检测与定时检测重叠。
- 配置文件权限为 `600`，Token 和 AccessKey 不显示在菜单或日志中。
- 自动使用 systemd 或 OpenRC；没有 init 服务时回退到 cron。
- 重复运行安装器可进入管理、保留配置更新、重置或卸载。

交互操作指服务器终端中的 `aliyun-guard` 管理面板。当前版本的 Telegram Bot 只负责发送通知，不读取 `/status`、`/start` 等控制命令。

## 支持系统

安装器支持下列 Linux 包管理器和发行版：

- `apt`: Debian、Ubuntu
- `dnf` / `yum`: RHEL、CentOS、Rocky Linux、AlmaLinux、Fedora
- `apk`: Alpine Linux
- `pacman`: Arch Linux
- `zypper`: openSUSE / SUSE

需要 `root`、可访问 PyPI 和 Python 3.8 或更高版本。脚本是 POSIX `sh`，同时支持直接执行和 `wget ... | sh`；所有交互都从 `/dev/tty` 读取，不会把脚本正文误当作菜单输入。

## 阿里云权限

建议创建独立 RAM 用户，至少授予：

- `AliyunECSFullAccess`：查询、启动和停止 ECS。
- `AliyunCDTReadOnlyAccess`：查询当月 CDT 公网流量。
- `AliyunBSSReadOnlyAccess`：查询当前月份的实例税前账单。

调试完成后可改为自定义最小权限策略。不要使用主账号 AccessKey。

## 安装

直接运行构建好的单文件安装器：

```sh
chmod 700 aliyun-guard-install.sh
./aliyun-guard-install.sh
```

文件放到自己的 HTTPS 地址后也可使用：

```sh
wget -qO- https://raw.githubusercontent.com/Felix666-ship-It/aliyun-guard/main/install.sh | sh
```

首次向导会依次设置检测间隔、通知模式、Telegram、AccessKey、Region、实例 ID、账号站点和流量阈值。保存实例前会执行只读 API 校验。

账单站点必须按 AccessKey 所属账号选择，而不是按 ECS Region 判断：

- 中国站账号：`business.aliyuncs.com`，通常返回 `CNY`。
- 国际站账号：`business.ap-southeast-1.aliyuncs.com`，通常返回 `USD`。

站点选错时常见错误是 `InvalidAccessKeyId.NotFound`；新版会把它标记为 `BSS 账单查询失败`，不会与已经成功的 CDT/ECS 结果混在一起。

若检测到旧项目 `/opt/scripts/monitor.py` 或 `#aliyun_monitor` cron，安装器会询问是否停用旧 cron，并先备份原 crontab。旧项目文件和 Telegram 控制 Bot 不会被删除。

## 管理命令

```sh
aliyun-guard                 # 打开交互式管理面板
aliyun-guard status          # 服务和最近检测状态
aliyun-guard run             # 立即执行并按配置通知
aliyun-guard dry-run         # 查询真实数据，但不执行开关机
aliyun-guard test-telegram   # 发送测试消息
aliyun-guard logs            # 最近 100 行日志
aliyun-guard logs-follow     # 持续查看日志
aliyun-guard restart         # 重启后台服务
aliyun-guard uninstall       # 交互式卸载
```

默认目录：

```text
/opt/aliyun-guard/config.json
/opt/aliyun-guard/state.json
/opt/aliyun-guard/logs/guard.log
/usr/local/bin/aliyun-guard
```

## 保活规则

每个实例每轮分别执行：

1. 调用 `ListCdtInternetTraffic` 查询 AccessKey 所属账号的当月 CDT 总流量。
2. 调用 `DescribeInstances` 查询指定 Region 中的 ECS 状态。
3. 调用 `DescribeInstanceBill` 查询当前月份、当前 ECS 实例的税前账单金额。
4. 流量低于阈值且 ECS 为 `Stopped` 时调用 `StartInstance`。
5. 流量达到或超过阈值且 ECS 为 `Running` 时调用 `StopInstance`。
6. 无论正常、动作、警告或错误，默认发送一条合并后的“阿里云保活检测完成”通知；通知内包含账单金额或具体 BSS 错误。

注意：CDT 返回的是账号级流量，不是单台 ECS 的独立流量。同一 AccessKey 下配置多台实例时，它们看到的是同一个流量值，可以为每台实例设置不同阈值。

## 从源码构建

```sh
python3 packaging/build_installer.py /path/to/aliyun-guard-install.sh
```

构建器同时生成 `.sha256` 校验文件。维护源码位于 `src/`，最终安装器将所有运行文件嵌入一个 POSIX shell 文件。

## 安全提醒

Telegram Bot Token 和阿里云 AccessKey 一旦在聊天、终端录屏或公开日志中出现，就应立即在 BotFather 和阿里云 RAM 控制台撤销并重新创建。不要把真实凭据提交到 Git 仓库。
