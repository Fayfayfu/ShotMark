# ShotMark · macOS 截图与离线 OCR

ShotMark 是一个使用 Swift 和 AppKit 编写的 macOS 原生菜单栏工具，把屏幕框选、图片标注和文字识别放在一次截图流程中。按下 `⌘⇧A`，选取屏幕区域，添加标注或识别其中的文字，然后复制到剪贴板。

文字识别使用系统内置的 Apple Vision，配置为简体中文和英文，不需要 API Key。当前版本为开发中的本地应用，具体功能及限制以本文为准；早期设计文档中的规划不代表全部已经实现。

**验证状态（2026-11-23）**：Release 构建与本地签名校验通过；现有自动化测试报告了失败，且未得到完整结束汇总。此版本尚未通过完整验收，详见 [验证记录](docs/verification.md)。

## 已有功能

- **快捷截图**：菜单栏入口与全局快捷键 `Command + Shift + A`；快捷键注册失败时保留菜单入口。
- **选区调整**：默认选中鼠标所在显示器的全屏，可重新框选、移动选区和拖动边缘调整大小。
- **图片标注**：矩形、椭圆、直线、箭头、画笔、文字和马赛克；支持颜色、线宽、字号和粗体控制，以及撤销、重做。
- **图片复制**：点击“完成”、按 `⌘C` 或双击选区内容，将合成后的 PNG 复制到剪贴板。
- **离线 OCR**：识别当前选区图像中的文字，展示可编辑结果和平均置信度；可复制全部或选中的文字。
- **复制反馈**：通过 OCR 面板按钮成功复制文字后，退出截图会话并显示复制提示。
- **多显示器处理**：为各显示器建立截图覆盖层，允许在其中一个显示器上选择区域。
- **异常处理**：包含屏幕录制权限提示、截图启动超时恢复、显示器配置变化检查以及剪贴板和保存失败提示。

## 环境要求

- macOS 15 或更新版本（由 Swift Package 声明）。
- Swift 6 工具链与 Apple Command Line Tools。
- 当前测试配置引用 `/Library/Developer/CommandLineTools/Library/Developer/Frameworks`；请安装 Command Line Tools。仅使用其他位置的 Xcode 工具链时，可能需要调整测试框架路径。
- 不依赖第三方 Swift Package。

## 从源码运行

安装 Command Line Tools（已安装可跳过）：

```sh
xcode-select --install
```

下载项目并构建：

```sh
git clone https://github.com/Fayfayfu/ShotMark.git
cd ShotMark/ShotMark
./Scripts/build-app.sh
open ShotMark.app
```

构建脚本会编译 Release 可执行文件，在 Swift 包目录生成 `ShotMark.app`，并进行本地 ad-hoc 签名。此仓库提供源码和构建脚本，目前没有经过 Apple 公证的安装包。

首次截图时，按系统提示授予屏幕录制权限。如授权后仍无法截图，退出应用后重新打开，再从菜单栏启动截图。

## 操作说明

1. 点击菜单栏中的 **ShotMark → 开始截图**，或按 `⌘⇧A`。
2. 直接使用默认全屏选区，或拖拽重新框选；选择“选区”工具可移动、调整选区。
3. 按需要添加标注。点击 **完成**、按 `⌘C` 或双击选区内容，复制图片并结束会话。
4. 需要提取文字时，点击 **OCR**。在结果面板中修改识别文本，再点击 **复制全部** 或 **复制选中**；成功复制后会结束截图会话。
5. 按 `Esc` 或点击 **取消**，结束本次截图。

| 快捷键 | 用途 |
| --- | --- |
| `⌘⇧A` | 启动截图 |
| `⌘C` | 在截图编辑状态下复制图片并结束会话；文本编辑控件获得焦点时按文本控件行为处理 |
| `⌘Z` | 撤销标注 |
| `⌘⇧Z` | 重做标注 |
| `Esc` | 取消当前截图 |

## 数据处理

当前应用代码使用 ScreenCaptureKit 捕获屏幕、Apple Vision 本地识别文字，没有接入云端 OCR，也没有应用自行发起的网络请求代码。截图与编辑状态保存在会话内存中，没有截图历史库；复制结果写入系统剪贴板。

代码中保留了通过 `UserDefaults` 配置保存 PNG 副本的逻辑，默认关闭。目前没有可用的设置界面来切换保存选项。

## 当前限制

- “设置…”菜单目前显示“设置尚不可用”。保存目录选择、云端 OCR 配置和 Keychain 密钥管理尚未实现。
- 工具栏的独立“复制图片”按钮尚未接入、处于禁用状态；可使用“完成”、`⌘C` 或双击选区复制图片。
- 多显示器支持当前屏幕上的选区，尚未实现跨多个显示器拼接同一个选区。
- OCR 结果与原图质量、版式有关；复杂多栏文字、表格和手写体的识别效果尚未专项验证。
- 自动化测试不等同于实际屏幕权限、全局快捷键和所有外接显示器组合的完整验收。验证范围见 [验证记录](docs/verification.md)。

## 开发与验证

在 `ShotMark/` Swift 包目录执行：

```sh
swift build
./Scripts/build-app.sh
```

在当前 Command Line Tools 环境中，测试运行器需要显式框架搜索路径：

```sh
swift test --enable-swift-testing --disable-xctest --no-parallel \
  -Xswiftc -F \
  -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
```

仅运行 `swift test` 在本次环境中会编译后静默结束，不能以退出码 0 判断测试通过；上述显式命令也发现了现有测试失败。请核对日志中的实际执行结果与最终汇总。

测试使用 Swift Testing，覆盖选区交互与坐标、标注渲染、撤销重做、OCR 结果排序与复制状态、截图协调与异常恢复等行为。

```text
ShotMark/
├── Package.swift
├── Scripts/build-app.sh
├── Sources/ShotMark/
│   ├── AppDelegate.swift
│   ├── Capture/       # 屏幕捕获、快捷键、会话管理
│   ├── Overlay/       # 选区与覆盖层交互
│   ├── Annotation/    # 标注工具、合成与撤销重做
│   ├── OCR/           # Vision 识别、结果面板、复制提示
│   ├── Settings/      # 本地偏好存储
│   └── Resources/     # 应用 Info.plist
└── Tests/ShotMarkTests/
```

## 项目文档

- [当前验证记录与手工验收清单](docs/verification.md)
- [早期设计规格](docs/superpowers/specs/2026-08-19-macos-screenshot-tool-design.md)
- [早期实现计划](docs/superpowers/plans/2026-08-19-macos-screenshot-tool.md)

早期文档记录目标和设计过程，包含尚未落地的功能；当前状态以源码、本文及验证记录为准。
