<div align="center">

# DeepSeek Replica for HarmonyOS

DeepSeek App Replica 的 HarmonyOS（OpenHarmony）适配版 —— 尽可能复刻 DeepSeek 官方手机端交互与视觉体验的客户端

[![Release](https://img.shields.io/github/v/release/forwardz666/deepseek-app-replica-ohos?style=flat-square&color=2563eb&label=Release)](https://github.com/forwardz666/deepseek-app-replica-ohos/releases/latest)
[![Platform](https://img.shields.io/badge/Platform-HarmonyOS%20%2F%20OpenHarmony-0b57d4?style=flat-square)](https://github.com/forwardz666/deepseek-app-replica-ohos)
[![License](https://img.shields.io/badge/License-GPL%20v3-blue?style=flat-square)](LICENSE)

<br />

[**📥 前往 Releases 下载 HAP 安装包**](https://github.com/forwardz666/deepseek-app-replica-ohos/releases/latest) · [**反馈问题**](https://github.com/forwardz666/deepseek-app-replica-ohos/issues)

</div>

---

## 项目简介

本仓库是 [DeepSeek App Replica（Android）](https://github.com/LiJiaHua1024/deepseek-app-replica) 的 **HarmonyOS / OpenHarmony 适配版本**，尽可能保留原版的交互与视觉体验。

与官方客户端一样未接入官方账号体系，改为直接使用你自己的 DeepSeek 开放平台 API Key（按量计费，Pay-as-you-go），只要账户额度充裕即可自由使用；所有会话数据均保存在设备本地。

> 本项目是一个独立的移植工程：**ArkUI 原生容器 + ArkWeb WebView** 承载上游的 React Web 交互层，通过 JS 桥把系统能力（API Key 存储、历史导入导出、外链打开等）暴露给 Web 层。所有前端构建产物已随仓库提交，克隆后无需 Node 环境即可直接构建 HAP。

## 与 Android 原版的差异

| 功能 | Android 原版 | HarmonyOS 版 |
|---|---|---|
| 对话、流式回复、深度思考、联网搜索 | ✅ | ✅（Web 层直连 DeepSeek API） |
| Markdown / KaTeX 公式 / Mermaid 图表 / 代码高亮 | ✅ | ✅ |
| 历史会话管理、搜索 | ✅ | ✅ |
| 导入 Android 版导出的数据备份（ZIP） | — | ✅ |
| 导出全部历史对话（进度显示，保存到 `Download/DeepSeek Replica/`） | ✅（SAF 选目录） | ✅（公共下载目录，首次启动申请授权） |
| 外观主题（浅色 / 深色 / 跟随系统） | ✅ | ✅（含系统深浅色自动跟随） |
| 中 / 英多语言 | ✅ | ✅ |
| 服务协议、帮助与反馈等外链 | 应用内浏览器 | 系统浏览器打开 |
| 语音对讲（麦克风录音） | ✅ | 未适配 |
| 相册选图发送（多模态输入） | ✅（应用内最近照片网格 + 相册） | 部分可用（经系统文件选择器选图；应用内相册网格未适配） |
| 保存图片到本地 | ✅（系统图库） | ✅（保存到 `Download/DeepSeek Replica/Images/`） |
| 返回键 / 侧滑手势状态机 | ✅（含预测性返回动画） | ✅（返回键与侧滑按 Web 协议逐层关闭；预测性返回动画未适配） |

> 当前针对 **平板 / PC（2in1）设备（OpenHarmony API 26）** 开发与验证，其他设备形态未逐一测试。

## 下载与安装

请前往 [GitHub Releases](https://github.com/forwardz666/deepseek-app-replica-ohos/releases) 页面获取最新发布的 HAP 文件。由于应用采用侧载方式分发（未上架应用市场），安装需要以下任一方式：

- **开发者模式 + hdc 安装（推荐）**：在设备的「设置 → 关于」中连点版本号开启开发者模式，随后：
  ```bash
  hdc install dsreplica-unsigned.hap
  ```
- **DevEco Studio 签名后安装**：使用 DevEco Studio 的「Build → Build App(s)/Hap(s)」或在工程中配置你自己的 `signingConfigs` 签名后安装。仓库内的 `build-profile.json5` 出于安全考虑未附带任何签名材料。

## 使用步骤

1. 安装并打开应用，进入「设置」。
2. 在 API 配置中填入你在 [DeepSeek 开放平台](https://platform.deepseek.com) 申请的 API Key。
3. 返回主页面即可开始对话；首次启动会申请「下载目录」权限（用于导出历史对话到 `Download/DeepSeek Replica/`）。
4. 如需迁移数据：在 Android 版中使用「导出所有历史对话」生成备份 ZIP，在本应用中导入即可。

## 技术架构

项目采用 ArkUI 原生容器承载 Web 交互内核的架构：

- **ArkUI 原生层**：基于 ArkTS 与 OpenHarmony SDK 26。`entry/src/main/ets/` 包含主页面（`Index.ets`，承载 ArkWeb WebView）与 JS 桥（`DeepSeekBridge.ets`），封装系统能力：API Key 与配置的本地存储、历史对话导出（Base64 分块传输写入公共下载目录）、外链打开、下载目录权限申请等。
- **Web 交互层**：与上游 Android 版同源的 React 18 + TypeScript 构建产物（`entry/src/main/resources/resfile/web/`），包含 KaTeX、Mermaid 与 Prism.js 排版渲染，直接由 ArkWeb 从本地加载，无需网络。
- **通信协议**：Web 层通过 `window.NativeAndroid` 风格的桥对象同步调用原生方法，原生通过 `CustomEvent` 向 Web 层派发异步事件（如导出状态、录音数据）。

## 源码构建

### 环境要求

- DevEco Studio（或配置好的鸿蒙命令行环境：Node.js、Hvigor、OpenHarmony SDK 26）

### 构建步骤

```bash
# 1. 克隆代码
git clone https://github.com/forwardz666/deepseek-app-replica-ohos.git
cd deepseek-app-replica-ohos

# 2. 还原二进制资源（应用图标与 KaTeX 字体以 base64 清单形式存储，保持仓库纯文本）
python3 scripts/restore_binaries.py

# 3. 构建 HAP（DevEco Studio 打开工程构建，或命令行）
hvigorw assembleHap --mode module -p product=default --no-daemon
```

构建输出：`entry/build/default/outputs/default/entry-default-unsigned.hap`（未配置签名时）。

> Web 层源码在上游仓库 [LiJiaHua1024/deepseek-app-replica](https://github.com/LiJiaHua1024/deepseek-app-replica)（`src/` 目录）。如需修改前端界面，请在上游工程中构建 Web 层后，将产物替换到 `entry/src/main/resources/resfile/web/`。

## 项目结构

```text
├── AppScope/                        # 应用级配置（应用名、图标、bundleName）
├── entry/
│   └── src/main/
│       ├── ets/
│       │   ├── bridge/              # JS 桥：系统能力封装（存储、导出、权限）
│       │   ├── entryability/        # UIAbility 入口（首启权限申请）
│       │   └── pages/               # 主页面（ArkWeb 容器）
│       ├── resources/
│       │   ├── base/                # 应用资源（图标、权限说明文案）
│       │   └── resfile/web/         # React Web 层构建产物（随仓库提交）
│       └── module.json5             # 模块配置与权限声明
├── scripts/
│   ├── restore_binaries.py          # 从 base64 清单还原二进制资源
│   └── binary-assets.*.b64          # 图标与字体的 base64 清单
└── build-profile.json5              # 工程构建配置（未含签名材料）
```

## 免责声明

本项目仅供个人技术研究与跨平台移植学习交流使用，非 DeepSeek 官方发布版本。项目内所有商标、标识及版权均归其各自所有者所有。

## 开源协议与致谢

本项目采用 [GPL-3.0 许可证](LICENSE)。

本项目的 Web 交互层与整体设计源自 **[DeepSeek App Replica（Android）](https://github.com/LiJiaHua1024/deepseek-app-replica)**，感谢原作者 **LiJiaHua1024** 的高质量开源工作 —— 本仓库的鸿蒙适配正是建立在这一基础之上；部分基础代码源自 DeepSeek 官方开源的 [chat-demo](https://github.com/deepseek-ai/chat-demo)（MIT 许可证），依其条款保留原作者版权声明。

对上述所有先行者与开源社区贡献者的成果表示敬意与感谢。
