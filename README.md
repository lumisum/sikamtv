# SikaMTV

SikaMTV 是一款音乐可视化视频生成器。用户导入背景图片或视频、音乐与歌词，即可生成带动态歌词、音乐视觉效果和背景动画的 MP4。

本仓库采用双平台并列结构，macOS 客户端是现有成熟版本，Windows 11 客户端正按相同产品流程独立开发：

| 目录 | 平台 | 技术 |
| --- | --- | --- |
| [`macos/`](macos/) | macOS | Swift、SwiftUI、AVFoundation、Metal、Accelerate、CoreText、Vision |
| [`win11/`](win11/) | Windows 11 | WinUI 3、Windows App SDK、Direct3D 11 / HLSL、Media Foundation |

两个客户端遵循相同的产品流程，并各自采用平台原生媒体技术。Windows 版已接入 NVIDIA 优先的 Direct3D 11 / HLSL 预览与导出合成、视频背景、歌词/文章、字体导入，以及 Media Foundation H.264/AAC MP4 生成；与 macOS 版的视觉特效和素材能力仍在持续对齐。

## macOS

详见 [`macos/README.md`](macos/README.md)。

```bash
cd macos
swift run MTVMusicVideo
./scripts/package_app.sh --install --open
```

## Windows 11

详见 [`win11/README.md`](win11/README.md)。WinUI 3 桌面应用需要 Windows 11 和 Visual Studio 2022 的 Windows App SDK / C++ 桌面开发组件。NVIDIA 图形与 NVENC 后端在搭载 NVIDIA 显卡的 Windows 设备上进行验证。

## 产品能力目标

- 背景图片 / 视频、多音频格式和 LRC / SRT 字幕
- 歌词视频与文章阅读两种模式
- 9:16、16:9、1:1 画面比例
- 音乐响应的可视化与场景动画
- 音乐循环、Direct3D GPU 加速预览与 H.264/AAC MP4 导出

macOS 客户端已提供主要产品功能；Windows 客户端的逐项实现状态以 [`win11/README.md`](win11/README.md) 为准。
