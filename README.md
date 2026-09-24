# Emu - 次世代 iOS RPG Maker MV / MZ 播放器

基于 Apple 原生 **SwiftUI + WebKit + Network.framework** 打造的高性能现代 RPG Maker 播放器，专为 iPhone / iPad 深度定制。

---

## 🌟 核心特性

- **零拷贝直读（In-Place Zero-Copy Loading）**：
  - 基于 iOS Security-Scoped Bookmarks，直接授权外部文件夹（如「文件」App、「下载」目录或外部存储），无需漫长复制等待，实现 0 秒秒开。
- **自定义键位映射与按键拖拽布局（Keymap Studio & Drag Layout）**：
  - 支持虚拟按键长按进入编辑模式，自由拖拽移动至任意顺手位置；
  - 内置标准 RPG、动作冒险、数字快捷栏等多种键位预设，支持键盘按键代码自定义映射。
- **WebKit WebAudio & OGG Vorbis 兼容**：
  - 针对 iOS WebKit 内核注入音频支持探测补丁与静音解码防护，解决原生 RPG Maker 游戏中 OGG 音效无声或闪退问题。
- **iOS 原生设计语言与深浅色自适应**：
  - 纯净自适应界面（浅色纯白 / 深色纯黑），大标题滚动收缩过渡；
  - 横屏导航栏采用系统单体原生胶囊控制岛，视野开阔通透。
- **超低延迟触觉反馈（CoreHaptics）**：
  - 深度模拟微动按键触觉反馈与动作爆发震感。
- **高颜值定制图标**：
  - 陶瓷白底座搭配复古透明科技彩色水晶手柄。

---

## 🏗️ 架构与源码结构

```
Emu/
├── Assets.xcassets                      # 应用图标与资源文件
├── EmuApp.swift                         # App 统一入口 (系统深浅色自适应)
├── Models/
│   ├── Game.swift                       # 游戏元数据、引擎枚举 (MV, MZ, WebGal)
│   └── KeyMapping.swift                 # 键位映射模型与预设配置
├── Services/
│   ├── LocalGameServer.swift            # 纯原生 Swift 静态 HTTP 服务器 (解决 CORS 与流式读取)
│   ├── GameLibraryManager.swift         # 沙盒/安全书签目录扫描与引擎嗅探
│   ├── KeyMappingManager.swift          # 键位持久化与布局坐标管理
│   └── HapticManager.swift              # 物理按键触觉反馈引擎
├── Views/
│   ├── Components/
│   │   └── GlassComponents.swift        # 流体组件与修饰器
│   ├── Controller/
│   │   ├── GlassActionButton.swift      # 触控晶体动作按键
│   │   ├── GlassDpadView.swift          # 流体悬浮十字方向键
│   │   ├── KeymapStudioView.swift       # 键位映射工作室设置面板
│   │   └── VirtualControllerOverlay.swift # 控制器覆盖层与拖拽调整
│   ├── Library/
│   │   ├── GameCardView.swift           # 游戏卡片 (自适应排版与启动)
│   │   └── GameLibraryView.swift        # 游戏库主界面与文件选择器
│   └── Player/
│       ├── GameWebView.swift            # WebGL 硬件加速容器与 OGG 补丁
│       └── GamePlayerView.swift         # 全屏游戏生命周期管理与服务启停
└── project.yml                          # XcodeGen 工程生成配置
```

---

## 🚀 编译与运行

本项目使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 管理 Xcode 工程：

```bash
# 1. 安装 xcodegen (如果尚未安装)
brew install xcodegen

# 2. 生成 Xcode 项目
xcodegen generate

# 3. 双击打开 Emu.xcodeproj，在 Xcode 中点击 Run 即可在模拟器或真机上运行！
```
