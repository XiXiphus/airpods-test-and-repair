**中文** | [English](README.md)

# AirPods Fix

一个原生 macOS 应用，用来诊断和修复常见的 AirPods 音频问题。

适用场景包括：AirPods 已连接但没声音、音质降级、输出设备选错、静音/音量异常，或者麦克风工作不正常。

## 普通用户

对大多数用户来说，直接使用 GitHub Releases 里的打包版即可。

1. 下载最新 `.dmg`
2. 打开磁盘镜像
3. 把 `AirPods Fix.app` 拖到 `Applications`
4. 正常启动 app

只是运行 app 的话，一般不需要 Xcode、Xcode Command Line Tools 或本地 Swift 工具链。

当前 release 可能还是未签名版本。如果 macOS 首次启动时拦截了 app，请对 app 点右键选择“打开”，或者到“系统设置 -> 隐私与安全性”里手动允许后再启动。

## 开发者

只有在你要参与开发时，才需要从源码构建。

- macOS 13 或更高版本
- Xcode Command Line Tools

常用命令：

```bash
./build.sh
./package-release.sh
```

- `./build.sh` 生成 `AirPods Fix.app`
- `./package-release.sh` 生成发布用 `.dmg`
- push `v*` tag 后，GitHub Actions 会自动构建并发布 release 产物

更详细的打包和发布说明见 [RUNTIME.md](RUNTIME.md)。

## 运行时依赖

运行时依赖取决于 app 的打包方式。

- GitHub Release 构建应当把 `blueutil` 一起打进 app
- 本地构建会优先使用系统里已有的 `blueutil`
- 如果缺少 `blueutil`，app 仍然可以使用扫描、诊断、扬声器测试、麦克风测试、软修复和中修复
- 如果缺少 `blueutil`，只有蓝牙重连不可用

另外，麦克风测试会请求麦克风权限；除此之外的功能不依赖麦克风权限。

## 功能

- 检测已连接的 AirPods 并显示电量
- 同时连接多副 AirPods 时可选择目标设备
- 诊断输出路由、立体声/单声道模式、采样率、静音状态和低音量
- 提供扬声器测试和麦克风测试
- 提供分级修复：
  - 软修复：刷新音频路由
  - 中修复：重启 `coreaudiod`
  - 硬修复：蓝牙重连
- 在刷新音频路由前会先临时静音，完成后恢复原来的静音状态，避免切到 MacBook 扬声器时突然外放
- 显示带时间戳的诊断日志

## 基本使用

1. 把 AirPods 连接到 Mac
2. 打开 app，等待自动扫描
3. 如果连接了多副 AirPods，先选择目标设备
4. 查看诊断区域
5. 按需运行扬声器或麦克风测试
6. 如果音频链路仍然异常，使用**一键修复**

## 系统要求

- macOS 13 (Ventura) 或更高版本
- AirPods 或 AirPods Pro

## 许可证

MIT
