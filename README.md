# Aliyun Guard：阿里云 CDT 流量保活、自动止损与账单通知

![Linux](https://img.shields.io/badge/OS-Linux-1793d1?logo=linux&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.8%2B-3776ab?logo=python&logoColor=white)
![Alibaba Cloud](https://img.shields.io/badge/Alibaba%20Cloud-China%20%26%20International-ff6a00)
![Init](https://img.shields.io/badge/Init-systemd%20%7C%20OpenRC%20%7C%20cron-4c566a)
![Telegram](https://img.shields.io/badge/Notify-Telegram-26a5e4?logo=telegram&logoColor=white)

Aliyun Guard 是一个面向阿里云 ECS 的交互式守护工具。它定时查询账号当月 CDT 公网流量、ECS 状态和当前实例税前账单，在流量安全时确保实例运行，达到阈值时自动关机止损，并在每轮检测结束后发送 Telegram 汇总。

本项目参考了 [10000ge10000/aliyun_monitor](https://github.com/10000ge10000/aliyun_monitor) 的核心思路，并针对实际部署中遇到的安装兼容、通知缺失、账单 Endpoint 混用、错误来源不清晰和更新困难等问题进行了独立重写。

## 核心能力

- **CDT 流量止损**：流量达到设定阈值后停止 ECS，防止继续产生公网流量。
- **自动保活恢复**：流量低于阈值而实例处于 `Stopped` 时自动启动；次月 CDT 重置后可自动恢复。
- **国内站与国际站账单**：分别支持人民币和美元账单 Endpoint，也允许自定义 BSS Endpoint。
- **错误来源分离**：CDT、ECS、BSS 和 Telegram 分别记录结果；账单失败不会阻断保活判断。
- **每轮 Telegram 汇总**：默认每轮都通知，也可切换为仅事件或仅错误通知；临时网络失败自动重试。
- **多账号、多地域、多实例**：每个实例可使用独立 AccessKey、Region、阈值和账单站点。
- **交互式管理面板**：增删改、暂停/恢复、立即检测、演练、日志、服务管理和 GitHub 更新均可在菜单完成。
- **多发行版安装**：兼容 `apt`、`dnf`、`yum`、`apk`、`pacman` 和 `zypper`。
- **多调度后端**：优先使用 systemd，其次 OpenRC；无 init 服务时自动回退到 cron。
- **安全更新**：更新前校验 GitHub `install.sh.sha256`，保留配置、状态和日志后重启服务。
- **并发保护**：检测任务带文件锁，避免后台巡检与手动执行重叠。
- **凭据保护**：Token、AccessKey 不写入日志，配置文件权限固定为 `600`。

## 保活逻辑

每个未暂停的实例会依次执行以下只读查询：

1. `ListCdtInternetTraffic`：查询 AccessKey 所属账号当月 CDT 总流量。
2. `DescribeInstances`：查询目标 Region 中指定 ECS 的状态。
3. `DescribeInstanceBill`：查询当前月份、当前 ECS 实例的税前账单。

查询完成后按以下规则决策：

| CDT 流量 | ECS 状态 | 自动操作 |
|---|---|---|
| 低于阈值 | `Running` | 保持运行 |
| 低于阈值 | `Stopped` | 调用 `StartInstance` 并等待状态确认 |
| 达到或超过阈值 | `Running` | 调用 `StopInstance` 并等待状态确认 |
| 达到或超过阈值 | `Stopped` | 保持关机 |
| 任意 | `Starting` / `Stopping` | 本轮不重复操作 |

> CDT 返回的是账号级总流量，不是单台 ECS 的独立流量。同一 AccessKey 下配置多台实例时，它们读取到相同流量，但可以设置不同关机阈值。

> BSS 账单查询完全独立。即使出现 `NoPermission`、`InvalidAccessKeyId.NotFound` 或 Endpoint 错误，CDT 与 ECS 查询成功后仍会继续执行保活决策，并把账单错误写入 Telegram 汇总。

## 管理面板

安装后直接输入 `aliyun-guard`：

<div align="center">
  <img src="docs/images/management-menu.png" width="520" alt="Aliyun Guard 管理面板" />
</div>

管理面板包含：

```text
 1) 查看运行状态
 2) 立即执行一轮检测
 3) 演练一轮（不执行开关机）
 4) 测试 Telegram 通知
 5) 查看监控实例
 6) 添加监控实例
 7) 编辑监控实例
 8) 暂停/恢复监控实例
 9) 删除监控实例
10) 修改全局设置
11) 查看最近日志
12) 重启后台服务
13) 更新 GitHub 版本
14) 退出
```

这里的交互操作位于服务器终端。当前版本的 Telegram Bot 只发送通知，不读取 `/status`、`/start`、`/stop` 等远程控制命令。

## 前置准备

### 1. Telegram 通知参数

- 使用 [@BotFather](https://t.me/BotFather) 创建机器人并获取 Bot Token。
- 使用 [@userinfobot](https://t.me/userinfobot) 获取接收消息的 Chat ID。
- 创建机器人后先在 Telegram 中打开它并发送 `/start`，否则私聊通知可能失败。

安装向导会调用 `getMe` 并发送测试消息，只有 Token 和 Chat ID 均可用时才会显示测试成功。

### 2. 阿里云 RAM 权限

不要使用主账号 AccessKey。建议创建独立 RAM 用户并授予：

- `AliyunECSFullAccess`：查询、启动和停止 ECS。
- `AliyunCDTReadOnlyAccess` 或 `AliyunCDTFullAccess`：查询 CDT 流量。
- `AliyunBSSReadOnlyAccess`：查询实例账单。

控制台入口：

- [阿里云中国站 RAM 控制台](https://ram.console.aliyun.com/users)
- [阿里云国际站 RAM 控制台](https://ram.console.alibabacloud.com/users)

调试完成后可以改成自定义最小权限策略。

### 3. 账单站点选择

账单站点必须按照 **AccessKey 所属账号** 选择，不能根据 ECS Region 猜测。

| 账号类型 | BSS Endpoint | 默认币种 |
|---|---|---|
| 阿里云中国站 | `business.aliyuncs.com` | `CNY` / `¥` |
| 阿里云国际站 | `business.ap-southeast-1.aliyuncs.com` | `USD` / `$` |
| 其他情况 | 安装向导中选择“自定义” | 自定义 |

站点选错时，常见错误是：

```text
BSS 账单查询失败: InvalidAccessKeyId.NotFound
```

该错误只影响账单显示，不会影响已经成功的流量查询和 ECS 保活。

## 支持系统

| 包管理器 | 发行版示例 |
|---|---|
| `apt` | Debian、Ubuntu |
| `dnf` / `yum` | RHEL、CentOS、Rocky Linux、AlmaLinux、Fedora |
| `apk` | Alpine Linux |
| `pacman` | Arch Linux |
| `zypper` | openSUSE、SUSE |

运行要求：

- `root` 权限。
- Python 3.8 或更高版本。
- 可以访问 GitHub、PyPI、阿里云 OpenAPI 和 Telegram API。
- 普通 SSH/VNC 交互终端。

安装器是 POSIX `sh` 脚本。即使通过 `wget ... | sh` 执行，所有菜单输入也会从 `/dev/tty` 读取，不会把脚本正文误判为用户输入。

## 一键安装

使用 `root` 登录任意可联网 Linux 服务器，然后执行：

```sh
wget -qO- https://raw.githubusercontent.com/Felix666-ship-It/aliyun-guard/main/install.sh | sh
```

也可以使用 `curl`：

```sh
curl -fsSL https://raw.githubusercontent.com/Felix666-ship-It/aliyun-guard/main/install.sh | sh
```

安装器会自动完成：

1. 检测发行版、包管理器、Python 和 init 系统。
2. 安装系统依赖并创建独立 Python 虚拟环境。
3. 写入运行程序、控制命令和卸载脚本。
4. 引导配置 Telegram、通知模式和检测间隔。
5. 引导添加一个或多个阿里云账号/实例。
6. 只读校验 AccessKey、CDT、ECS、BSS、Region 和实例 ID。
7. 创建 systemd/OpenRC 服务或 cron 回退任务。
8. 启动后台检测并发送第一轮汇总。

若检测到旧项目 `/opt/scripts/monitor.py` 或 `#aliyun_monitor` cron，安装器会询问是否停用旧 cron，并先备份原 crontab。旧项目文件和 Telegram 控制 Bot 不会被自动删除。

## 常用命令

```sh
aliyun-guard                 # 打开交互式管理面板
aliyun-guard status          # 查看服务和最近检测状态
aliyun-guard run             # 立即执行一轮真实检测并通知
aliyun-guard dry-run         # 查询真实数据，但不执行开关机
aliyun-guard test-telegram   # 发送 Telegram 测试消息
aliyun-guard update          # 校验并安装 GitHub 最新版本
aliyun-guard logs            # 查看最近 100 行日志
aliyun-guard logs-follow     # 持续查看日志
aliyun-guard start           # 启动后台调度
aliyun-guard stop            # 停止后台调度
aliyun-guard restart         # 重启后台调度
aliyun-guard uninstall       # 交互式卸载
```

## Telegram 通知

默认 `always` 模式会在每轮检测结束后发送一条合并通知：

```text
阿里云保活检测完成
时间: 2026-07-16 03:20:00
汇总: 1 个实例，0 个动作，0 个警告，0 个错误

[OK] HK (i-xxxxxxxx)
  流量: 46.22 / 180.00 GB
  ECS: Running
  账单: ¥12.34 (CNY)
  结果: 流量安全，实例运行正常
```

账单失败时会明确标注来源：

```text
[ERROR] HK (i-xxxxxxxx)
  流量: 46.22 / 180.00 GB
  ECS: Running
  账单: 查询失败
  结果: 流量安全，实例运行正常
  错误: BSS 账单查询失败: NoPermission ...
```

通知模式可在“修改全局设置”中选择：

- `always`：每轮都通知，默认选项。
- `events`：仅动作、警告、错误或状态变化时通知。
- `errors`：仅检测错误时通知。

## 从 GitHub 更新

在管理面板选择“更新 GitHub 版本”，或者执行：

```sh
aliyun-guard update
```

更新流程：

1. 从本仓库 `main` 分支下载 `install.sh`。
2. 下载 `install.sh.sha256` 并校验文件完整性。
3. 校验失败立即退出，不覆盖当前程序。
4. 保留 `config.json`、`state.json` 和日志。
5. 更新代码与依赖，然后自动重启后台服务。

从不带更新菜单的早期版本升级时，可重新执行一键安装命令，在已有配置菜单中选择“更新程序并保留配置”。完成这一次升级后，后续即可直接使用菜单或 `aliyun-guard update`。

## 暂停和恢复实例

维护、锁定或暂时不希望自动开关机时：

1. 执行 `aliyun-guard`。
2. 选择“暂停/恢复监控实例”。
3. 选择目标实例。

暂停后，该实例不会调用 CDT、ECS、BSS 或自动开关机 API；其他实例继续正常检测。

## 文件与服务

```text
/opt/aliyun-guard/
├── aliyun_guard.py      # 检测、保活、账单和通知核心
├── manager.py           # 交互式管理面板
├── control.sh           # aliyun-guard 命令入口
├── config.json          # 配置文件，权限 600
├── state.json           # 最近检测状态，权限 600
├── service_backend      # 当前调度后端
├── logs/guard.log       # 主日志
└── venv/                # Python 虚拟环境
```

常见服务名：

```sh
systemctl status aliyun-guard.service   # systemd
rc-service aliyun-guard status          # OpenRC
crontab -l | grep aliyun-guard          # cron 回退
```

## 故障排查

先执行：

```sh
aliyun-guard status
aliyun-guard logs
aliyun-guard dry-run
```

| 错误 | 常见原因 | 处理方法 |
|---|---|---|
| `MissingAccessKeyId` | AccessKey 为空或配置损坏 | 进入管理面板编辑实例 |
| `InvalidAccessKeyId.NotFound` | AccessKey 已删除，或 BSS 国内/国际站点选错 | 重新创建 AccessKey，并检查账单站点 |
| `NoPermission` | RAM 权限不足 | 补充 ECS、CDT 或 BSS 只读/操作权限 |
| `chat not found` | Chat ID 错误，或尚未与 Bot 建立会话 | 向 Bot 发送 `/start` 并重新测试 |
| `reset by peer` / TLS 超时 | Telegram 或出口网络临时异常 | 保持 IPv4 优先，检查代理/防火墙；程序会自动重试 |
| `未找到实例` | Region 或 Instance ID 不匹配 | 在 ECS 控制台核对 Region ID 和实例 ID |

日志会明确使用 `CDT 流量查询失败`、`ECS 实例查询失败`、`BSS 账单查询失败` 或 `Telegram ... 失败` 标注来源，避免一条模糊错误掩盖其他已成功的检查。

## 卸载

```sh
aliyun-guard uninstall
```

卸载器会要求输入 `YES` 确认，并询问是否先把 `config.json` 备份到 `/root`。随后会移除服务、cron 任务、命令链接和 `/opt/aliyun-guard`。

## 开发与验证

源码结构：

```text
src/                         运行源码
packaging/install.template.sh 安装器模板
packaging/build_installer.py  单文件安装器构建器
tests/test_guard.py           行为测试
install.sh                    构建后的单文件安装器
install.sh.sha256             安装器校验文件
```

运行测试：

```sh
python3 -m unittest discover -s tests -v
shellcheck -s sh install.sh src/control.sh src/uninstall.sh packaging/install.template.sh
```

重新构建单文件安装器：

```sh
python3 packaging/build_installer.py ./install.sh
```

## 与参考项目的区别

| 项目 | `10000ge10000/aliyun_monitor` | Aliyun Guard |
|---|---|---|
| 安装兼容 | 主要针对 Debian/RHEL，并包含 Alpine/VNC 扩展 | 支持六类包管理器和三种调度后端 |
| 通知方式 | 异常通知与定时日报 | 默认每轮合并通知，可切换通知模式 |
| 账单错误 | 可能与其他查询混在同一错误中 | BSS 独立显示，失败不阻断保活 |
| 日常管理 | 重跑安装器，另有可选 Telegram 控制 Bot | 统一终端面板和 `aliyun-guard` 命令 |
| 更新方式 | 重跑安装器下载运行文件 | 菜单自更新，并执行 SHA-256 校验 |
| Telegram 控制 | 可选远程开关机控制 | 当前版本仅发送通知，不接收控制命令 |

## 安全提醒

- 不要把真实 Bot Token、AccessKey ID 或 AccessKey Secret 提交到 GitHub。
- 一旦凭据出现在聊天、终端录屏或公开日志中，应立即在 BotFather 和阿里云 RAM 控制台撤销并重新创建。
- 使用 RAM 子账号和最小必要权限，不要使用主账号 AccessKey。
- 配置文件虽然限制为 root 可读，仍应配合服务器磁盘、备份和 SSH 权限管理。
- 本工具不能替代阿里云费用中心的预算告警和消费限额。

## 免责声明

1. 本项目仅供学习与技术交流使用。
2. 作者不对因脚本异常、API 变更、依赖故障、网络阻断或配置错误造成的流量损失、服务中断或费用承担责任。
3. 强烈建议同时在阿里云费用中心设置预算告警和兜底限额，并定期人工核对账单。

## 致谢

感谢 [10000ge10000/aliyun_monitor](https://github.com/10000ge10000/aliyun_monitor) 提供 CDT 流量守护、国内/国际账单适配和多实例管理的项目思路。本项目在此基础上结合实际部署问题重新设计了安装、运行、错误处理、通知与更新流程。

如果这个项目对你的多节点管理或流量止损有帮助，欢迎 Star 本仓库并提交 Issue 反馈实际运行环境与错误日志。
