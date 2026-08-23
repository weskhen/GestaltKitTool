# GestaltKitTool

[English](./README.md) | 简体中文

> 项目由 **WeskTool** 更名为此版本起的 **GestaltKitTool**。保留 Bundle identifier `com.wesk.vtool`，以便已安装的 App 原地升级，保留本地备份库、补丁库及已写入的 MobileGestalt 状态。

GestaltKitTool 是一个运行在 iPhone 上的 SwiftUI MobileGestalt 工具。它读取 `com.apple.MobileGestalt.plist`，提供能力预设、字段编辑、备份/导入/恢复、跨 App 沙盒文件浏览、系统文件检查等功能。App 沙盒外的所有文件访问均通过 `bad_query` 沙盒逃逸实现。

> **警告**：本项目使用私有 API 并修改系统缓存数据。错误的 MobileGestalt 值可能导致系统功能或 UI 异常，可能需要恢复设备。仅在自有或被授权的设备上使用。

> **注意**：GestaltKitTool 不安装越狱、Bootstrap 或常驻 Daemon，也不向第三方应用注入代码，不会被检测为越狱。

## 功能

### MobileGestalt 标签页

- 灵动岛设备子类型及备用支持标志
- 「关于本机」中显示的设备型号名称
- 开关机提示音、充电限制、轻点唤醒、Camera Control
- Apple Pencil、Action Button、Collision SOS 设置
- 全天候显示、AOD 鲜明度、墙纸视差、液态玻璃低性能模式
- 台前调度、iPad App 兼容性、Nugget 的 iPadOS `CacheData` 补丁
- Siri AI 美区、Apple 内部安装、内部存储、安全研究设备模式
- 字段编辑器：搜索并编辑 `CacheExtra` 与 plist 顶层的 String、Integer、Float、Boolean、Data、Array、Dictionary 类型值
- 备份库：备份、导入、导出、恢复、删除本地备份，写入前做预校验
- 一键 App 备份：将任意 App 的整个数据容器备份到 GestaltKitTool 的私有容器

预设遵循 Nugget 的分阶段应用模型。开关表示下一次写入的变更，所有选中的变更通过底部 Apply 按钮统一提交。成功写入后选中状态清空。写入冲突值的选项互斥。成功写入或恢复后，自动刷新 SpringBoard。

### Explorer 标签页

- 浏览设备上所有 App 数据容器、App Group 容器和 System Group 容器
- `bad_query` 绕过沙盒，列出并读取任意 App 私有数据容器中的文件
- 通过面包屑路径导航、收藏常用路径、输入自定义绝对路径
- 文件预览及类型识别：属性列表（树形视图）、JSON（美化输出）、文本、图片（PNG/JPEG/HEIC）、十六进制 dump、二进制
- 跨目录递归搜索，支持增量结果与取消
- 批量文件操作：多选删除、移动、导出

### Inspector 标签页

- 读取敏感系统文件，展示 `bad_query` 沙盒逃逸的影响范围
- 跨 6 大类的 10 个目标文件：Identity & Gestalt、System Containers、App Sandboxes、Bundle Containers、Network Configuration、System Information
- 属性列表树形浏览，键值检查
- 导出读取结果以供分析

### Settings 标签页

- 语言切换：英语 / 简体中文（默认跟随系统）
- 诊断面板 6 项测试：bad_query 可用性、沙盒租约、容器发现、文件读取、目录列举、MobileGestalt 写入探测
- 安全清理：扫描并清理 App 缓存/tmp 目录以释放磁盘空间
- 首次启动引导，3 步

## 环境要求与签名

- 支持的系统版本：iOS 26.0–26.6.1、iOS 27 beta 1 至 beta 4
- Xcode 及可将 App 安装到目标设备的签名方式
- 设备需开启开发者模式
- Bundle identifier：`com.wesk.vtool`

GestaltKitTool 在访问 MobileGestalt 前会检查当前系统版本。iOS 26 支持基于 bad_query 作者声明，未在所有 26.x 版本上测试。iOS 27 beta 保留精确构建号白名单（24A5355q、24A5370h、24A5380h、24A5390f），防止未测试版本意外运行。如未来 Apple 修复 bad_query 将及时调整支持范围。

Apple 可能随时更改这些私有行为。

## 编译

在 Xcode 中打开 `GestaltKitTool.xcodeproj`，为 target 选择自己的开发团队后编译。命令行：

```sh
xcodebuild \
  -project GestaltKitTool.xcodeproj \
  -scheme WeskTool \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  build
```

不带签名仅校验源码：

```sh
xcodebuild \
  -project GestaltKitTool.xcodeproj \
  -scheme WeskTool \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

> **Scheme 名称说明**：Xcode Scheme 仍使用 `WeskTool`，以保持 `SWIFT_OBJC_BRIDGING_HEADER` 路径、target UUID、`TEST_HOST` 引用内部稳定。本次仅修改了显示的产品名（`PRODUCT_NAME` / `CFBundleDisplayName`）及工程文件名。

IPA 文件、证书、Provisioning Profile、开发团队标识符、本地 Xcode 用户数据均排除在仓库之外。

## 使用

1. 安装并打开 GestaltKitTool，等待读取 MobileGestalt。
2. 使用 **MobileGestalt** 标签页进行预设、字段编辑和备份管理。
3. 使用 **Explorer** 标签页浏览 App 沙盒或设备路径。
4. 使用 **Inspector** 标签页检查敏感系统文件。
5. 使用 **Settings** 标签页切换语言或运行诊断。
6. 成功写入或恢复后，SpringBoard 自动刷新。

## 致谢

- [Nugget](https://github.com/leminlimez/Nugget) — MobileGestalt 预设与 iPadOS `CacheData` 方案（借鉴）
- [FilzaSlop](https://github.com/0xjohnnydev/FilzaSlop) — ContainerManager 文件访问研究（借鉴）
- [bad_query](https://github.com/forcequitOS/bad_query) — 基于路径的 ContainerManager 沙盒逃逸（依赖）
- [0xJohnny](https://x.com/0xjohnny) — MobileHouseArrest / ContainerManager 概念验证（借鉴）
- [neospring](https://github.com/rooootdev/neospring) — WebKit respring 实现（基于开发）
- [GestaltEdit](https://github.com/frs0n/GestaltEdit) — MobileGestalt 标签页基于此项目开发（基于开发）
- [FilzaJailedDS](https://github.com/34306/FilzaJailedDS) — 沙盒逃逸验证与写入加固思路（借鉴）

GestaltKitTool 为独立实现，与 Apple 及上述列出的项目均无隶属关系。

## 许可证

[MIT License](./LICENSE)
