# 发布前验证记录

验证日期：2026-11-23。

## 验证环境

- macOS 26.3.1 (a)，Apple Silicon（arm64）。
- Apple Swift 6.2.3，Command Line Tools 工具链。
- 包声明的最低部署版本为 macOS 15；本次未在 macOS 15 实机验证。

## 验证范围

本次发布整理了现有开发工作区的源码、测试和构建脚本，没有改动应用功能。复制到主目录的 27 个源码、测试、构建配置文件与开发工作区逐字节一致。

| 检查 | 结果 |
| --- | --- |
| Debug 与测试目标编译 | 成功 |
| `Scripts/build-app.sh` | 成功，生成 arm64 `ShotMark.app` |
| `codesign --verify --deep --strict ShotMark.app` | 通过 |
| 应用 Info.plist 校验 | 通过 |
| 自动化测试 | 未通过；两次显式执行合计观察到 14 个不同用例失败，且均未得到完整结束汇总 |
| 真实桌面手工验收 | 本次未执行 |

直接执行 `swift test` 时，测试目标编译成功，但未打印用例执行结果。为生成的 SwiftPM 运行器补齐 Testing 框架搜索路径后，实际观察到测试运行；随后又用 `--no-parallel` 串行执行进行核查。两次执行均出现失败记录，并在输出完整测试汇总前结束，尽管命令退出码为 0。因此退出码不足以证明通过，不能报告全套通过或完整通过率。

复现命令见 [README](../README.md#开发与验证)。以下为两次日志中失败用例名称的去重合集；不是一次完整执行的统计。尚未逐项定位原因，部分结果可能与本机图形环境或测试夹具有关。

```text
asymmetricTwoTimesCropPreservesExactPixels
coordinatorWatchdogRecoversAHungProviderAndAllowsAnotherStart
invalidOneDimensionalDragRestoresExistingSelection
newerOCRRequestWinsWhenOlderRequestCompletesLast
ocrPanelRemainsInteractiveInDefaultSelectionMode
overlayOCRUsesComposedImageAndKeepsEditingSession
rendererPaintsSinglePointBrushAsRoundDot
rendererPixelatesMosaicRectUsingNearestNeighborBlocks
rendererUsesImagePointCoordinatesWithoutFlippingYAxis
renderingLinePreservesLogicalSizeAndSourcePixels
replacingSelectionInvalidatesInFlightOCRWithoutTouchingNewEditor
saveDirectoryURLRoundTripsThroughDefaults
saveFailureDismissesOverlaysBeforePresentingError
selectedCanvasPreservesScreenshotVerticalOrientation
```

失败断言涉及图像坐标及像素、选区拖动、OCR 面板与异步状态、保存目录 URL 表达、窗口清理和超时恢复。本次上传没有为消除测试失败而修改应用源码或测试预期。

已检查准备提交的源码与文档，未发现常见 GitHub Token、API Key、私钥、AWS Access Key 模式或个人本机用户目录路径。该检查为模式扫描，不构成完整安全审计。构建缓存、生成的 `.app`、系统杂项文件及本地调试报告不纳入仓库。

## 手工验收清单（本次未执行）

以下条目供实际桌面环境验收使用，未勾选表示本次发布未验证，不能由自动化测试结果推定通过。

- [ ] 屏幕录制权限未授权时显示提示；授权并重启后能够截图。
- [ ] `⌘⇧A` 可启动截图；快捷键冲突时菜单栏入口仍可使用。
- [ ] 单显示器及多个显示器下，选区与导出 PNG 的位置、方向、像素对应正确。
- [ ] 默认全屏可重新框选，选区移动与缩放正确。
- [ ] 矩形、椭圆、直线、箭头、画笔、文字、马赛克的显示与导出正确。
- [ ] 颜色、线宽、字号、粗体、撤销与重做符合操作预期。
- [ ] “完成”、`⌘C`、选区内双击都能复制图片；在其他应用中粘贴验证。
- [ ] `Esc` 与“取消”可退出会话，不产生截图历史文件。
- [ ] 断网时识别真实中英文截图，并人工核对识别文本。
- [ ] OCR 结果可编辑、复制全部和复制选中；成功复制后退出会话并显示提示。
- [ ] OCR 出错后仍可继续编辑或取消截图。
- [ ] 默认不保存 PNG 副本；如通过配置开启保存，核对输出目录与文件内容。

## 已知未完成功能

完整设置界面、独立“复制图片”按钮、云端 OCR、Keychain 密钥管理和跨屏拼接选区均未实现。参阅 [README](../README.md) 获取当前使用方法。
