# 使用 Pocket 3 Controller

[English](../guide.md) · [繁體中文](../zh-Hant/guide.md) · 简体中文

[文档入口](README.md) · [项目概览](../../README.zh-Hans.md)

本指南涵盖已发布的 **0.0.1 beta 1，build 9**；`main` 是 beta 2、build 11 开发版本。停用或标为实验性的控制，不表示对应机身功能已支持。

## 安装与首次启动

从 [beta 1 发行页](https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.1) 下载 DMG 或 ZIP，把 **Pocket 3 Controller.app** 放入 **Applications**。需要 macOS 27 与 Apple Silicon；发行页也提供 SHA-256 checksums。

此 Beta 使用本地开发证书，尚未 Apple 公证。若 macOS 阻挡首次启动，先确认下载来源，再依「系统设置 → 隐私与安全性 → 仍要打开」提示允许该 App。目前没有 Homebrew cask；其他 Mac 的首次启动行为尚未全面验证。

以 USB 连接 Pocket 3，在机身选择 **Webcam**，再于 App 选择相机并连接。不需要更改 Mac 的 Wi-Fi。

## 访问权限与隐私

访问选项决定 AI 与外部客户端可以做什么：

| 选项 | 行为 |
|---|---|
| **仅手动操作（Manual only）** | 默认。可以使用 App 预览与手动控制；没有授予 AI 观察或动作权限。 |
| **只允许观察（Observe only）** | 允许帧观察与图片问答，不授予相机移动权限。 |
| **允许观察与移动（Observe and move）** | 允许观察及符合条件的相机动作；每次动作仍检查能力与验证要求。 |

连接时会请求 macOS 相机权限。使用音频时需要麦克风权限，明确启动 Bluetooth 操作时才请求其权限。若先前拒绝，先在系统设置更改相应权限，再重试该功能。

**停止（Stop）** 取消待执行的相机工作并尝试相应保持操作。**隐私暂停（Privacy pause）** 停止目前工作并释放采集输入。关闭主窗口会保留菜单栏服务；**退出（Quit）** 才会结束服务。菜单栏图标左键开面板，右键开功能菜单。

## USB 预览与格式

先使用 Beta 基本流程验收的 **1920×1080、NV12、30 fps**。选择其他分辨率、帧率或输入格式后，重新连接才会生效。720p30 与 1080p24 也已取得新帧，4K30 NV12 有较早的有界实测证据。格式菜单反映设备声明，不代表每个组合都会产生帧。

竖屏结果取决于机身物理方向及选定模式。早期竖屏试验在改变机身方向后通过；不能假设只选择竖屏分辨率就会旋转相机或启用全部原生竖屏模式。UYVY／H.264 路径及 4K60 仍没有通过的取像结果。没有新帧时，回到已测的 1080p30 NV12。

快照只采集一张图片；CLI 会写入你明确提供的 `--output` 路径。可以预览不代表 App 已能录像或控制全部机身录像模式。

## 手动云台控制

按住方向按钮或拖动摇杆，移动 pan／tilt；离中心越远，要求的移动越快。松开输入、失焦或按停止都会结束手势。手动操作优先于 AI，通过 USB 位置目标控制，Mac 保留原有网络。

先做小幅手势，确认画面结果。物理速度、完整范围及最坏情况的停止延迟尚未校准。停止后稳定读回是软件证据，不是机械急停认证。若 App 报告无法确认停止，请查看相机实际状态，不要自动重复前一个移动。

原生快速回中及正反面翻转仍在开发，慢速 USB 移动不是等价替代。

## 缩放与实验性 Roll

使用缩放滑块或减／加按钮。百分比表示设备报告范围内的控制行程，不是光学放大倍率。已测设备报告原始值 100–400、step 1，并完成 100 → 200 → 100 往返。其他设备或连接必须使用各自读到的能力。

Roll 标为**实验性**，数值是设备控制单位，不是已校准的物理角度。目前只有 0 → 1 → 0 原始值往返的验证；物理方向及较大调整中的停止仍待验收。缩放或 pan 通过不等于 Roll 也通过。

## Bluetooth 只读状态

开启 Bluetooth 连接面板，明确扫描、选择相机并配对。机身出现提示时确认配对要求。此流程不会让 Mac 加入相机 Wi-Fi。

配对后，面板可显示机身回报的电量、充电、姿态、AF 模式、白平衡及曝光。用读取操作更新三个机身设置值；缺少或过期的数据不视为已确认的目前状态。低电量与持续下降趋势会分别显示，不和充电状态混为一谈。

这些值是只读数据。BLE peer 不自动视为选定的 USB 相机，BLE 姿态也未与 USB 坐标校准。机身可以支持点按对焦，而 App 内的点按对焦仍不可用；AF 模式读回不是设置对焦点的功能。

## 本地 AI

在「AI 引擎与接入」选择引擎。Apple Foundation Models 需要相应系统模型可用。MLX Qwen 3.5 为可选，通过下载操作取得，预留约 3.1 GB 模型空间。下载需要网络，推理使用已在本地的模型。

询问图片前先选择「只允许观察」。OCR 和条码工具也在本地运行。需要相机动作时才授予控制权；程序会独立检查权限和工具结果，不把模型措辞当作依据。不确定的回答需要核对，尤其是对象数量及「动作已完成」的宣称。

## MCP 与 CLI

保持 App 开启，从接入页复制 MCP JSON，或使用[首页设置](../../README.zh-Hans.md#mcp-与-cli)。安装后的 helper 路径是 `/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3`，MCP 使用 `args: ["mcp"]`。它通过私有本地 Unix socket 调用 App，遵守访问选项。

```sh
'/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3' status
'/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3' snapshot --output "$PWD/pocket3-frame.jpg"
'/Applications/Pocket 3 Controller.app/Contents/MacOS/pocket3' ask --engine apple --question '读取画面上可见的标签。'
```

MCP 缩放先取得 `camera_status.capture.sessionID`，以 `expectedSessionID` 传给 `camera_zoom_status`，再选择符合其 minimum／maximum／step 刻度的整数 `rawValue` 调用 `camera_set_zoom`。检查 `completed` 与 `verified`，再取得新帧。取消或未确认的动作不能触发自动连续重试。

## 常见问题与更新

| 现象 | 下一步 |
|---|---|
| 找不到相机 | 检查 USB 数据连接，并在机身选择 Webcam。 |
| 列出相机但没有预览 | 检查相机权限；若另一个取像 App 占用设备，先结束它，再以 1080p30 NV12 重连。 |
| MCP 取像被拒绝 | 保持 App 已连接，并先选择「只允许观察」。 |
| 模型不可用 | 检查系统模型是否可用，或完成可选 MLX 模型下载。 |
| AF、快速回中或翻转不可用 | 这些 App 能力尚未完成，单纯配对不会启用它们。 |
| 电量持续下降 | 核对机身电量与供电连接；USB 配置值不是电流实测值。 |
| 关闭主窗口后相机仍在使用 | 以「隐私暂停」释放采集，或「退出」终止服务。 |

beta 1 已包含本项目 Sparkle 设置，Beta signed feed 也已完成 Keychain 签名与发布。公开 HTTPS 下载的 feed 及 ZIP 已通过 CryptoKit 与本项目 Ed25519 公钥验证。自动检查依你的偏好启用，也可通过 [GitHub Releases](https://github.com/YuhuanStudio/Pocket3-Controller/releases) 手动下载。实际从一个已发布版本更新到下一版的安装、替换与重启尚未验收；不要把 `main` 的开发版视为更新的公开下载。
