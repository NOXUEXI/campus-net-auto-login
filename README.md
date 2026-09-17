# CampusNetAutoLogin

校园网 Portal 认证自动登录工具（Windows / PowerShell）。

开机或解锁后自动完成 Portal 认证，掉线自动重连，全程静默无窗口。

项目脱胎于作者自己宿舍网络的自动化需求。Portal 认证协议各家学校参数不一，换学校使用需要自行调整 `config.json`。

## 解决的问题

以前每次开机：打开浏览器 → 手动输账号密码 → 等认证通过 → 才能上网。

现在：开机 / 解锁后约 20 秒自动完成认证，之后每 5 分钟巡检一次，掉线自动重连。

## 特性

- **多时机触发** — 登录 Windows 后 20 秒、屏幕解锁后、每 5 分钟后台巡检
- **静默运行** — VBS 启动器包装，不弹窗口、不闪黑框
- **已在线零打扰** — 检测到已联网时只发一个查询请求就退出，不提交账号密码
- **断线自愈** — 认证成功但运营商尚未拨号完成时，自动等待并重拨
- **异常提醒** — 需要验证码或密码错误时弹系统气泡，同一提醒 30 分钟内不重复
- **密码本地加密** — 使用 Windows DPAPI 加密，绑定当前 Windows 账户，文件被拷走也无法解密
- **非校园网环境自动跳过** — 检测不到门户时静默略过，日志 30 分钟最多记一条

## 工作原理

1. `GET /api/account/status` — 查询当前是否已认证
2. 已在线 → 直接退出，不发送账号密码
3. 未在线 → `POST /api/account/login` 提交认证
4. 运营商尚未拨号成功 → 等待并 `POST /api/account/redial` 重拨

## 快速开始

### 环境要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带）
- Python 3（仅 `Find-Portal.py` 辅助脚本需要）

### 安装

1. 把整个文件夹放到任意目录，例如 `C:\CampusNetAutoLogin`
2. 复制 `config.example.json` 为 `config.json`，填入你学校的门户地址和账号
3. 双击 `Setup-Password.cmd` 录入密码，本地 DPAPI 加密后写入 `cred.dat`
4. 右键 `Install-Task.ps1` → 使用 PowerShell 运行，注册计划任务

### 找到你学校的门户地址

不确定门户 IP，先在浏览器里手动登录一次校园网，然后运行：

```bash
python Find-Portal.py
```

脚本会读取本机 Edge / Chrome 的历史记录，把疑似 Portal 认证的地址列出来。

该脚本只在本地运行，不联网，不上传任何数据。

## 配置项

| 字段 | 说明 |
|---|---|
| `portal` | 认证门户地址，例如 `http://10.0.0.1` |
| `username` | 校园网账号，通常是学号 |
| `nasId` | NAS 标识，Portal 认证参数，多数学校填 `1` |
| `switchip` | 交换机 IP，留空则使用门户返回的默认值 |
| `dialWaitSeconds` | 认证成功后等待拨号的秒数 |
| `dialMaxTries` | 拨号最大重试次数 |
| `notifyCooldownMinutes` | 同一异常提醒的最小间隔，单位分钟 |

## 文件说明

| 文件 | 作用 |
|---|---|
| `Setup-Password.cmd` | 双击录入或修改密码，唯一需要手动操作的一步 |
| `Check-Status.cmd` | 双击查看在线状态、任务状态、最近日志 |
| `Uninstall.cmd` | 双击卸载自动登录 |
| `campus-login.ps1` | 主脚本：状态查询 + 认证 + 重拨 |
| `launcher.vbs` | 静默启动器，让控制台窗口完全不出现 |
| `Install-Task.ps1` | 注册 Windows 计划任务 |
| `Setup-Password.ps1` | 密码录入的后端逻辑，负责 DPAPI 加密 |
| `Find-Portal.py` | 辅助工具，从浏览器历史里找认证入口 |
| `config.example.json` | 配置模板，使用时复制为 `config.json` |
| `cred.dat` | 加密后的密码，自动生成，请勿提交 |
| `login.log` | 运行日志，最多保留 400 行 |

## 常见问题

**回家或者换了 Wi-Fi，会不会一直报错？**
不会。检测不到校园网门户时静默跳过，日志 30 分钟最多记一条。

**提示需要验证码怎么办？**
门户偶发要求验证码，脚本无法自动识别。收到气泡提醒后手动登录一次，之后会恢复自动。

**学校改了密码？**
重新运行一次 `Setup-Password.cmd`。

**登录失败了想查原因？**
双击 `Check-Status.cmd`，日志最后 15 行就是原因。

**重装系统后怎么恢复？**
拷贝整个文件夹，右键 `Install-Task.ps1` 用 PowerShell 运行，再运行 `Setup-Password.cmd` 录入密码。计划任务名称为 `CampusNetAutoLogin`。

**想立刻真实测一次登录？**

```powershell
powershell -ExecutionPolicy Bypass -File .\campus-login.ps1 -ForceLogin -Force
```

`-ForceLogin` 会跳过「已在线就退出」的判断，真实提交一次认证。

## 卸载

双击 `Uninstall.cmd`，会询问是否同时删除保存的密码。之后手动删除文件夹即可，不留残留。

## 免责声明

本项目仅用于自动化登录**你自己的**校园网账号，请勿用于他人账号或任何未授权场景。使用前请确认符合所在学校的网络使用规定。

## License

[MIT](LICENSE)
