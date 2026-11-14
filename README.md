# Epic Games Launcher：UE 下载卡死 / `IS-EO-SERVICE_UNAVAILABLE` 修复笔记

> Windows 上 Epic Games Launcher 下载虚幻引擎时速度掉到 0、进度卡在 1 GB 左右、
> 最后报 `Install failed`，并伴随 `II-E1007` / `IS-EO-SERVICE_UNAVAILABLE`。
> 这是 2026-11 一次真实排障的完整记录与可复现修复步骤。

**English summary**: On Windows, the Epic Games Launcher may stall while
downloading Unreal Engine and then fail with `IS-EO-SERVICE_UNAVAILABLE`.
The cause was three problems stacked on top of each other: a slow CDN path, a
broken `Dev-Distro` Epic Online Services updater, and a launcher started from a
shell with missing `PROCESSOR_ARCHITECTURE`. Repairing EOS, disabling the
Windows system proxy, and relaunching with the correct environment restored
downloads to 26–33 MB/s. See [Quick fix](#快速修复三分钟).

## 适用范围

症状命中以下任意几条，本文大概率适用：

- 下载速度先是有 0.5–1 MB/s，然后彻底停住
- 安装目录长时间停在某个整数附近（例如 0.9–1.1 GB）
- Launcher 报 `Install failed`
- 错误码是 `II-E1007` 或 `IS-EO-SERVICE_UNAVAILABLE`
- 进程列表里 `EpicOnlineServices` 启动几秒后自己退出

不适用的情况：硬盘空间不足、杀毒软件拦截、Windows 版本过旧——这些会有别的错误码。

## 快速修复（三分钟）

需要：Windows、管理员 PowerShell、Epic Games Launcher 已安装。

```powershell
# 在仓库根目录执行
powershell -ExecutionPolicy Bypass -File .\scripts\fix-epic-launcher.ps1
```

脚本会做四件事，并在结束时打印如何还原：

1. 记录当前系统代理状态
2. 修复 Epic Online Services 组件
3. 关闭 Windows 系统代理（v2rayN 等软件可以继续开着）
4. 带正确的 `PROCESSOR_ARCHITECTURE` 重新拉起 Launcher

然后在库里点 UE 版本的「继续」。下载应当走直连，实测稳定在 26–33 MB/s。

想先只看不改：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\fix-epic-launcher.ps1 -DryRun
```

只想修 EOS、不动代理：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\fix-epic-launcher.ps1 -KeepSystemProxy
```

事后恢复系统代理：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\fix-epic-launcher.ps1 -RestoreProxy
```

## 根因：三个问题叠在一起

单看任何一个都不足以解释现象，三个同时存在才会「速度先慢后停、然后报 EOS 不可用」。

### 1. 网络层：CDN 路径本身很慢

2026 年这次排障时，Epic 的下载域名由台湾节点承接。本机实测：

| 检查 | 结果 |
| --- | --- |
| `cdn2.unrealengine.com` 解析 | 台中节点 |
| `epicgames-download1.akamaized.net` 解析 | 台北 HiNet |
| 换阿里 / 腾讯 / 114 / Cloudflare DNS | 返回同一个台湾 IP，**改 DNS 无效** |
| 真直连握手 | 0.47 s |
| 走本地代理握手 | 5.3 s |
| 订阅节点吞吐上限 | 200–300 KB/s，跑不动 37 GB |

结论：**换节点解决不了速度问题**，代理在这条路径上是负收益。

### 2. EOS 组件层：Dev-Distro 版更新器坏了

`EpicOnlineServices` 是 `Dev-Distro` 版本，自更新时缺少 `--mode` 参数：

```text
LogUpdaterService: Error: No updater mode specified
```

进程以 exit 77 退出。

### 3. 启动层：环境变量残缺 + localhost 被代理劫持

从命令行重启 Launcher 时，如果继承了空的 `PROCESSOR_ARCHITECTURE`，
EOS 的 Node 服务会报：

```text
Unsupported architecture: unknown
```

然后以 exit 71 退出。手动启动 EOS 又会报缺少 `EOS_SESSION_GUID`（exit 91）——
说明 EOS 必须由 Launcher 带着会话拉起，**不能手动 `Start-Service`**。

此外，Windows 系统代理会把发往 `localhost` 的 EOS 请求一并劫持，导致
`Sending exchange code to EOSH failed`，最终
`EoshState = Disabled, Reason = Unavailable`。

## 手工修复步骤

不想跑脚本就按这三步来。

### 步骤 1：修复 EOS 组件

以管理员身份运行，且必须在该目录内执行：

```powershell
Push-Location "C:\Program Files (x86)\Epic Games\Epic Online Services"
& ".\EpicOnlineServices - Update.cmd" /b
Pop-Location
```

成功后版本号会变成类似：

```text
5.8.1-58751156+++UE5+Release-EOSH-5.5-62c6c8-Windows
```

### 步骤 2：关闭 Windows 系统代理

保留代理软件本身运行，只关系统级开关：

```powershell
$p = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Set-ItemProperty -LiteralPath $p -Name ProxyEnable -Value 0
```

如果用了 TUN 模式，下载期间也请关掉，否则 localhost 流量同样会被接管。

### 步骤 3：带正确环境变量启动 Launcher

```powershell
$env:PROCESSOR_ARCHITECTURE = "AMD64"
$env:PROCESSOR_ARCHITEW6432 = "AMD64"
Start-Process "C:\Program Files\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe"
```

然后在库里点「继续」。

## 验证

```powershell
# Epic CDN 是否可达。返回 302 或 403 都算通（403 是 S3 根路径的正常响应）
curl.exe -sS -I --ssl-no-revoke --max-time 10 https://cdn2.unrealengine.com/

# EOS 是否在监听
Get-NetTCPConnection -State Listen -LocalPort 35783 -ErrorAction SilentlyContinue

# Launcher 日志里的关键行
Select-String -LiteralPath "$env:LOCALAPPDATA\EpicGamesLauncher\Saved\Logs\EpicGamesLauncher.log" `
  -Pattern "EoshPatcher|exchange code|ErrorCode" | Select-Object -Last 10
```

下载过程中直接看目录增长速度更直观：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\check-epic-cdn.ps1 -InstallDir "E:\UE\Install\UE_5.8"
```

修复成功的标志：

| 指标 | 修复前 | 修复后 |
| --- | --- | --- |
| 下载速度 | 0.5–0.9 MB/s，随后 0 | **26–33 MB/s** |
| EOS 进程 | 6 秒后自动退出 | 持续运行 |
| 日志 | `EoshState = Disabled` | `Successfully got exchange code` |
| 下载结果 | `Install failed` | `NumFailedDownloads: 0` |

本次实例最终安装完成：29.88 GB、250,810 个文件、`Build.version` 为
`5.8.4` / Changelist `58902052`，整体约 30 分钟。

## 不要做的事

1. **不要手动 `Start-Service EpicOnlineServices`**。它缺少 Launcher 传入的会话参数，
   单独启动必然失败，而且会让排障方向跑偏。
2. **不要从环境变量残缺的终端重启 Launcher**。缺 `PROCESSOR_ARCHITECTURE` 会传染给 EOS。
3. **下载期间不要开 TUN 或系统代理**。EOS 依赖 localhost 通信，被劫持就不可用。
4. **不要指望换 DNS 或换节点提速**。这条 CDN 路径两侧都慢，直连才是最优解。

## 常见误判

| 你以为的问题 | 实际情况 |
| --- | --- |
| CDN 被墙了 | 根路径返回 403 是 S3 正常响应，不代表不可达 |
| 换个快节点就好了 | 节点上限 200–300 KB/s，远低于直连的 30 MB/s |
| 改 hosts / DNS 能绕开 | 四个公共 DNS 返回同一批 IP，无效 |
| 手动启动 EOS 能救 | 反而会掩盖真实错误码 |
| 引擎下载坏了 | 是 Launcher 的 EOS 会话失败，与引擎包无关 |

## 环境

| 项目 | 版本 |
| --- | --- |
| OS | Windows |
| Epic Games Launcher | 20.3.8 |
| 代理工具 | v2rayN 7.25.6（TUN + 系统代理 10808） |
| Unreal Engine | 5.8.4 / `5.8.4-58902052+++UE5+Release-5.8` |

不同版本的行为可能不同，本文记录的是这次可复现的事实与推理过程，供参考。

## 许可

[MIT](LICENSE)。欢迎补充不同版本下的现象与修复。
