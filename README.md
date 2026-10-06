# Snaplet

使用 Swift + AppKit 开发的原生 macOS 截图工具。当前已编写区域截图、预览、复制图片、保存 PNG，以及可修改并持久化的全局快捷键；编译和单元测试通过，完整桌面截图流程尚待授权后验收。标注、贴图、滚动截图、OCR 和录屏尚未实现。

## 环境

- macOS 14 或更新版本
- Xcode 16 或更新版本，且已选择其命令行工具
- Swift 6.0 或更新版本
- 无第三方依赖

## 开发与运行

在项目目录执行：

```sh
make run
```

应用显示菜单栏图标和基础窗口。关闭窗口后应用继续常驻；通过菜单栏重新打开，或选择“退出 Snaplet”。

## 截图

1. 按默认全局快捷键 **⌥A（Option + A）**，点击“开始区域截图”，或在菜单栏选择“区域截图…”。默认值与本机 iShot 的区域截图设置一致。
2. 首次使用需要在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 Snaplet（不同系统版本可能显示为“屏幕录制”）。如系统要求，退出后重新启动应用。
3. 在任意显示器上拖动框选，松开鼠标后显示预览；Esc 或右键取消。一次截图限制在开始拖动的显示器内，暂不支持跨屏拼接。
4. 点击“复制图片”（⌘C）或“保存 PNG…”（⌘S）。复制操作会替换系统剪贴板内容，保存使用原生文件对话框。

截图使用 ScreenCaptureKit 的单帧采集接口，不常驻录屏。框选和预览窗口排除在捕获内容之外。预览按比例显示，导出的 PNG 保留捕获像素尺寸；关闭预览后释放其图片引用。目前只保留一个预览窗口。

点击主窗口中的“截图快捷键”按钮后按下新的组合键，Esc 取消。组合键需包含 Command、Control 或 Option。设置保存在应用 UserDefaults 中；无法注册时提示更换，修改失败时尝试恢复原快捷键。系统全局热键使用 Carbon 接口，不需要辅助功能权限。

Snaplet 使用独占热键注册，避免一个按键同时触发两个截图工具。若 iShot 或其他应用仍占用 ⌥A，需先退出该工具，再重启 Snaplet；也可以为 Snaplet 修改快捷键。

```sh
make build      # Debug 应用：build/debug/Snaplet.app
make release    # Release 应用：build/release/Snaplet.app
```

打包脚本使用本地 ad-hoc 签名，适合本机开发；对外分发需要另行配置正式签名与公证。当前打包的是本机架构。

## 在 Xcode 中编辑

用 Xcode 打开 `Package.swift`。项目由 Swift Package Manager 管理，并非 `.xcodeproj`。可以在 Xcode 中编译和调试可执行目标；检查实际菜单栏应用行为时，使用 `make run` 启动包含 `Info.plist` 的 `.app` 包。

## 目录

```text
Sources/Snaplet/
  main.swift                 应用入口
  AppDelegate.swift          应用生命周期与菜单栏
  MainWindowController.swift 基础 AppKit 窗口
  CaptureCoordinator.swift   截图流程与权限提示
  SelectionOverlay.swift     多显示器框选遮罩
  CaptureService.swift       ScreenCaptureKit 单帧采集与 PNG 编码
  CapturePreviewController.swift 预览、复制和保存
  GlobalShortcut.swift       全局快捷键注册与录入
Resources/Info.plist          应用元数据
scripts/build-app.sh          编译、打包与本地签名
```

## 后续功能

按 [分阶段实现计划](docs/ROADMAP.md) 推进：基础截图验收 → 标注 → 贴图与图库 → 高级截图/取色 → OCR/翻译 → 录屏/录音 → 性能与发布。计划记录每阶段的范围、验收条件、当前状态和本机 iShot 快捷键映射。

## 验证

`swift test` 覆盖框选到采集坐标的翻转、PNG 尺寸与颜色往返，以及快捷键解析和序列化。实际桌面捕获、多显示器/Retina 行为与全局快捷键需在授权后的图形会话中验证，单元测试不能替代这些检查。
