# WeatherBar · macOS 状态栏天气

常驻菜单栏的原生天气工具：一行字看天气，点开是完整面板。SwiftUI + AppKit，Universal 2（Apple Silicon / Intel），无第三方依赖。

![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-GPLv3-green)
![Arch](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-lightgrey)

## 功能

| 模块 | 说明 |
|---|---|
| 状态栏 | 图标 + 温度，随天气与昼夜自动切换；深色/浅色菜单栏自适应 |
| 天气面板 | 主面板：实况 / 逐小时 / 逐日；鼠标移到面板上，左侧弹出**独立浮窗**显示当天详情，鼠标移到某一天的横条上则切换成那一天的详情（逐小时、太阳与月亮、黎明、魔法时光、降水、风速湿度），今天额外带日月轨迹、月相、太阳 |
| 曲线 | 风速/湿度/气压/露点/紫外线/体感/降水/云量，右键卡片即可切换 |
| 地区管理 | 搜索添加、收藏 12 个、点击地区名即可切换、右键菜单、`⌘1`…`⌘9` |
| 首次引导 | 指向菜单栏的浮层指引，三步完成，可随时重播 |
| 多天气源 | Open-Meteo、Apple Weather（WeatherKit REST）、和风、心知、高德；自动降级 + 熔断 |
| 单位 | °C/°F、km/h · m/s · mph、hPa · inHg · mmHg |
| 应用内更新 | Sparkle 2：设置页 / 右键菜单点「检查更新」即自动下载、就地替换并重启，无需手动拖拽 |
| 其他 | 离线缓存、开机启动、中英双语地名、无 Dock 图标 |

## 数据源与免费额度

| 提供商 | 免费额度 | 是否需要 Key |
|---|---|---|
| Open-Meteo | 10,000 次/日 · 300,000 次/月（非商用） | 否（默认） |
| Apple WeatherKit | 500,000 次/月（含开发者会员） | 是 |
| 和风天气 | 0–50,000 次/月 免费 | 是 |
| 心知天气 | 免费版（个人开发者） | 是 |
| 高德天气 | 个人开发者配额 | 是 |

`自动` 模式：中国大陆坐标优先和风 → 心知 → 高德 → WeatherKit → Open-Meteo；海外优先 WeatherKit → Open-Meteo。全部失败时回落缓存并提示离线。

各源 API Key 存于 macOS Keychain，不写入配置文件、不打印日志、不上报。

## 安装

从 [Releases](https://github.com/cat-clever/weatherbar/releases) 下载 `.dmg`，双击挂载后，把 **WeatherBar** 拖到同一窗口里的 **Applications** 文件夹上即可完成安装。

未签名版本首次打开需：

```bash
xattr -dr com.apple.quarantine /Applications/WeatherBar.app
```

或右键 → 打开。

## 更新

装好一次之后就**不用再碰 dmg**了：

- 设置 → 通用 → **软件更新** → 点「检查更新」，发现新版点「安装更新」，下载、替换、重启全自动；
- 或右键菜单栏图标 → 「检查更新…」；
- 也可以打开「自动检查更新 / 自动下载并安装」，新版本会在后台下好，退出应用时自动装。

> 前提：WeatherBar 必须位于「应用程序」文件夹。直接从 dmg 或下载目录双击打开时，macOS 会把应用跑在临时只读路径下（App Translocation），系统不允许就地替换，Sparkle 会拒绝更新——设置页会给出提示，把 app 拖进「应用程序」后即恢复全自动。

## 构建

**本项目不在本地编译**，全部由 GitHub Actions 在 `macos-15` runner 上完成，产出 Universal 2（`arm64` + `x86_64`）通用包。

```bash
# 触发云端构建
gh workflow run build.yml
gh run watch

# 取回产物
gh run download -D ./dist
```

本地仅需 XcodeGen 生成的工程用于阅读代码，不参与构建。CI 会强制校验 `lipo -info` 同时包含两个架构，缺一即失败。

## 项目结构

```
WeatherBar/
├─ App/            应用入口与装配
├─ StatusBar/      NSStatusItem 宿主、popover、右键菜单
├─ Onboarding/     首次引导浮层
├─ State/          WeatherStore / PlaceStore
├─ Services/
│  ├─ Providers/   多天气源协议、适配器、熔断、天气码映射
│  ├─ Astro.swift  日出日落、月相、黎明、魔法时光
│  ├─ Geo.swift    定位与地理编码
│  └─ Storage.swift Keychain / 偏好 / 缓存 / 调度
├─ Views/          SwiftUI 面板与设置
├─ Models/         数据模型
└─ Design/         色板与格式化
```

开发文档见 [docs/开发文档.md](docs/开发文档.md)。

## 隐私

- 坐标仅用于请求天气，不做持久化上报，不接入任何分析 SDK。
- 位置权限可拒绝，拒绝后仍可手动选择地区。
- 缓存文件位于 `~/Library/Application Support/WeatherBar/cache/`，可在设置中清除。

## 许可

本项目采用 **GNU General Public License v3.0**，全文见 [LICENSE](LICENSE)。

这意味着：

- 你可以自由使用、修改、再分发，但衍生作品必须以同等协议开源；
- 分发二进制时须同时提供对应源代码；
- **不得通过 App Store 分发** —— GPLv3 与 App Store 的 DRM/再分发限制不兼容。本项目仅通过 GitHub Releases 分发。

第三方天气数据版权归各提供商所有，使用时须遵守其条款与署名要求（面板底部已展示当前数据来源）。
