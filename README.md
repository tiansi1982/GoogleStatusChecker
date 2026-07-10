# GoogleStatusChecker

> macOS 状态栏小程序 · 一眼看清当前网络能否访问 Google 美国

GoogleStatusChecker 在 macOS 菜单栏（右上角）放一个圆形指示灯，定期检测当前网络环境下对 Google 美国（`www.google.com`）的访问情况，并用红 / 黄 / 绿三色实时反馈。适合需要判断代理 / VPN 出口地域、或排查网络连通性的场景。

## 状态灯含义

| 颜色 | 含义 | 触发条件 |
| :---: | :--- | :--- |
| 🟢 绿灯 | 可正常访问 **Google 美国** | 最终落在 `www.google.com`，页面无国家重定向，且无 `kHL`/`gl` 非 US 标识 |
| 🟡 黄灯 | 能访问 Google，但**不是美国版本** | 被重定向到其他国家域名（如 `google.co.jp`、`google.com.hk`），或页面内有 JS/meta 跳转到其他 Google 域，或检测到非 US 国家代码 |
| 🔴 红灯 | **无法访问** Google | 连接超时 / 出错 / 非 2xx–3xx 状态码 / 最终落地域名不是 google |
| ⚪ 灰灯 | 检测中 | 正在发起请求，尚未拿到结果 |

## 工作原理

每隔 **5 分钟**自动检测一次，流程如下：

1. 用桌面版 Chrome 的 User-Agent 请求 `https://www.google.com/`（`Accept-Language: en-US,en;q=0.9`）。
2. 使用 **无痕会话**（`URLSessionConfiguration.ephemeral`）：不读写 Cookie、不使用缓存、`reloadIgnoringLocalCacheData`，确保每次都是真实探测。
3. 跟随 HTTP 重定向，记录最终落地 URL。
4. 判定逻辑：
   - 超时 / 出错 / 状态码不在 `200..<400` / 落地域名不含 `google` → **红灯**
   - 落地 `www.google.com` / `google.com` 时，进一步扫描页面内容：
     - 检测 `location.replace(...)` / `location.href = ...` / `<meta refresh>` 是否指向其他 Google 域 → 命中则 **黄灯**
     - 检测 `kHL="xx-XX"`、`gl=XX` 等国家标识 → `US` 为绿灯，其余为黄灯
     - 都没有 → 默认 **绿灯**（视为美国版）
   - 落地是其他 `google.*` 域名（如 `google.co.jp`）→ **黄灯**

这样设计是因为：很多网络环境下 `google.com` 本身能打开，但页面会在前端用 JS 把你跳到某个地区版本，单纯看 HTTP 状态码会被骗过去。本程序既看最终 URL，也看页面内的重定向和国家标识。

## 系统要求

- **macOS 11.0 (Big Sur) 及以上**
- **Apple Silicon（arm64）** —— 默认只编译 arm64；如需 Intel 支持见下文「自定义构建」
- 从源码编译需要 Xcode Command Line Tools（`xcode-select --install`）

## 快速开始

### 方式一：从源码编译（推荐）

```bash
# 1. 安装命令行工具（已装可跳过）
xcode-select --install

# 2. 进入项目目录，一键编译打包
cd GoogleStatusChecker
./build.sh

# 3. 运行
open GoogleStatusChecker.app
```

编译产物 `GoogleStatusChecker.app` 会生成在当前目录。状态栏右上角会出现一个圆形指示灯。

### 方式二：直接使用预编译的 .app

如果你拿到了别人编译好的 `GoogleStatusChecker.app`（拷贝/下载来的）：

```bash
# 1. 去掉隔离属性（否则会提示"已损坏"或"无法验证开发者"）
xattr -cr /path/to/GoogleStatusChecker.app

# 2. 首次启动：右键 -> 打开（不要直接双击），弹窗点"打开"
#    放行一次后，以后就能正常双击启动了
open /path/to/GoogleStatusChecker.app
```

> 因为程序使用临时签名（adhoc），没有 Apple 开发者证书公证，所以从别处拷来的版本首次会被 Gatekeeper 拦截，需要上面两步放行。在自己机器上编译则无此问题。

## 使用说明

程序运行后只活在状态栏，**不占用 Dock 位置**（`Info.plist` 中 `LSUIElement=true`）。

**点击状态栏的指示灯**弹出菜单：

| 菜单项 | 作用 |
| :--- | :--- |
| 状态：xxx | 当前检测结果（仅显示，不可点） |
| 上次检测：HH:mm:ss | 最近一次检测的时间 |
| 立即重新检测（⌘R） | 马上再测一次，不必等定时器 |
| 在浏览器中打开 Google（⌘O） | 用默认浏览器打开 `https://www.google.com/` |
| 退出 GoogleStatusChecker（⌘Q） | 退出程序 |

把鼠标悬停在指示灯上，还会显示当前状态的文字提示（tooltip）。

### 开机自启动

把 `GoogleStatusChecker.app` 拖到 **系统设置 → 通用 → 登录项与扩展 → 登录项**（macOS Ventura 及以上），或在「登录项」里点 `+` 添加即可。

## 分发到其他 Mac

本程序是 arm64 单架构，可在任意 Apple Silicon Mac 上使用。分发方式：

```bash
# 打包
zip -r -X GoogleStatusChecker.zip GoogleStatusChecker.app
```

把 zip 拷到目标 Mac 解压后，执行：

```bash
xattr -cr /path/to/GoogleStatusChecker.app
open /path/to/GoogleStatusChecker.app   # 首次右键->打开
```

## 自定义构建

`build.sh` 支持环境变量调整：

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `ARCHS` | `arm64` | 目标架构。设为 `"arm64 x86_64"` 可编译 universal 二进制（同时支持 Intel Mac） |
| `MIN_OS` | `11.0` | 最低支持系统版本 |

示例：

```bash
# 编译 universal（Intel + Apple Silicon 通吃）
ARCH="arm64 x86_64" ./build.sh

# 提高最低系统要求到 macOS 13
MIN_OS=13.0 ./build.sh
```

### 修改检测频率

检测间隔硬编码在 `main.swift` 中：

```swift
private static let checkInterval: TimeInterval = 300 // 5 分钟自动检测一次
```

改成你想要的秒数后重新 `./build.sh` 即可。

## 项目结构

```
GoogleStatusChecker/
├── main.swift       # 全部源码（约 400 行，纯 Swift + AppKit，无第三方依赖）
├── Info.plist       # 应用配置（LSUIElement=true 隐藏 Dock 图标）
├── build.sh         # 一键编译打包脚本
└── README.md        # 本文档
```

## 调试

查看运行时日志（`print` 输出会进系统日志）：

```bash
open GoogleStatusChecker.app && \
log stream --predicate 'process == "GoogleStatusChecker"' --style compact
```

黄灯 / 红灯路径会打印检测到的重定向目标或国家代码，便于排查。

## 常见问题

**Q: 双击 .app 提示「已损坏」或「无法验证开发者」？**
A: 程序用的是临时签名（adhoc），未做 Apple 公证。终端执行 `xattr -cr /path/to/GoogleStatusChecker.app` 去掉隔离属性，然后右键 → 打开首次放行即可。

**Q: 明明能打开 Google，为什么显示黄灯？**
A: 你的网络出口虽然能到 Google，但被 Google 重定向到了非美国版本（比如 `google.co.jp`、`google.com.hk`）。黄灯正是为了提示这种情况——「能上 Google，但不是美国 Google」。检查你的代理/VPN 出口节点地区。

**Q: 一直显示红灯，但浏览器能打开 Google？**
A: 程序用无痕会话、禁缓存探测，比浏览器更严格。可能是浏览器用了本地 DNS 缓存或 Cookie。先点「立即重新检测」确认；若仍红灯，用 `log stream` 查看具体原因（超时 / 状态码 / 非 google 域名）。

**Q: 会在后台偷跑流量吗？**
A: 不会。程序每 5 分钟只请求一次 `https://www.google.com/`，无任何上传、无 Cookie、无缓存、无遥测。源码就一个文件，可自行审查。

**Q: 如何完全卸载？**
A: 在菜单里点「退出 GoogleStatusChecker」，然后删除 `GoogleStatusChecker.app` 即可。程序不写任何配置文件、不存任何数据，删完即净。

## 技术栈

- 语言：Swift
- 框架：Cocoa / AppKit / URLSession
- 依赖：无第三方依赖，仅用系统框架
- 构建：`swiftc` + `lipo` + `codesign`，无需 Xcode 工程

## License

MIT License © 2026 tiansi
