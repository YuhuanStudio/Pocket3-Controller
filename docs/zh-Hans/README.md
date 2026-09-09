# Pocket 3 Controller 文档

[English](../README.md) · [繁體中文](../zh-Hant/README.md) · 简体中文

← [项目首页](../../README.zh-Hans.md)

目前下载是 **0.0.1 beta 1，build 9**；`main` 正在开发 **beta 2，build 21**。已安装版本的功能范围，以 [beta 1 发行页](https://github.com/YuhuanStudio/Pocket3-Controller/releases/tag/v0.0.1-beta.1) 为准。

## 使用 App

先阅读完整的 **[简体中文使用指南](guide.md)**：涵盖安装、权限、USB 格式、手动控制、缩放与 Roll、BLE、本地 AI、MCP、常见问题及更新。

| 文件 | 内容 |
|---|---|
| [项目概览与安装](../../README.zh-Hans.md) | 下载、首次启动、Webcam 设置、功能与 MCP 设置 |
| [完整使用指南](guide.md) | 从连接相机到本地 AI／MCP 的日常操作与问题排查 |

## AI

- [本地视觉 AI 深度研究](../AI_RESEARCH.md)：模型选择、语义定位、跟踪、VLA 边界与可量测的产品优先顺序。
- [可复现的定位评测](../../Evaluation/Grounding/README.md)：公开数据来源与评分契约。

## 技术文档与验证记录

以下是**主要以繁体中文维护、保留原日期的工作文档**，不是每份都已翻译成三语。旧产品名称、旧测试条件及早期支持矩阵不覆盖目前发布范围；请一起看 [最新工作清单](../../TODO.md)。

| 文件 | 内容 |
|---|---|
| [连续云台控制](../CONTINUOUS_GIMBAL.md) | USB 手势、松开／Stop 及物理验证界线 |
| [Bluetooth 遥测](../BLUETOOTH_TELEMETRY.md) | 电量、充电、姿态、新鲜度及设备关联限制 |
| [机身设置协议](../CAMERA_SETTINGS_PROTOCOL.md) | 只读 AF、白平衡、曝光报告；协议数据不表示 setter 已可用 |
| [对焦读回](../FOCUS_READBACK.md) | 可取得的对焦信息及 App 点按 AF 尚未完成的原因 |
| [实验性 USB Roll](../USB_ROLL.md) | 原始单位、能力检查及有限真机验收 |
| [硬件验收](../HARDWARE_ACCEPTANCE.md) | 各次真机试验的日期、条件与通过／失败范围 |
| [AI 验证](../AI_VALIDATION.md) | 模型评估、失败案例及模拟／物理相机动作的区分 |
| [验收审核](../ACCEPTANCE_AUDIT.md) | 历史软件 gate 与明列的未测项目 |
| [YunAudio 一致性](../YUNAUDIO_PARITY.md) | 共用视觉设计与 App 通用操作 |
| [设备能力路线图](../DEVICE_CAPABILITY_ROADMAP.md) | 待实现机身功能及启用前所需证据 |
| [目前工作清单](../../TODO.md) | 持续进行的实现与验证 |
| [参与开发](../../CONTRIBUTING.md) | 范围、可复现修改、设计一致性与硬件测试报告 |

## 发布、签名与数据

| 文件 | 内容 |
|---|---|
| [发布流程](../RELEASE.md) | 来源身份、安装包验证、GitHub assets 及 signed feed 发布 |
| [本地开发签名](../LOCAL_SIGNING.md) | 固定本地签名身份；不等于 Developer ID 或公证 |
| [测试产物政策](../TEST_ARTIFACTS.md) | 临时获取、保留报告，以及移除旧媒体后的 hash 记录 |
| [权利与第三方声明](../../NOTICE.md) | 自有来源权利及各依赖的授权 |

私有 `artifacts/` 与 `research/` 不随公开来源提供，因此工作文档指向它们的历史链接可能无法开启。移除的图片不会被重制来冒充原证据，清理记录也不是新硬件测试。首页图库只包含同语的 App 界面截图，不含私有相机照片。
