# SikaMTV for Windows 11

Windows 客户端使用 WinUI 3 / Windows App SDK 构建原生桌面界面；Direct3D 11 后端会枚举高性能显卡并优先选择 NVIDIA 适配器。图形效果由 HLSL 像素着色器在 GPU 上合成。无 NVIDIA 显卡时，图形设备会回退到系统可用的硬件适配器。

## 当前已实现

- 三栏原生桌面工作区：素材库、比例匹配的预览、分组参数和项目素材槽。
- 图片 / 视频、音频、LRC / SRT / TXT / Markdown 导入，素材库搜索，以及将素材明确加入工作区。
- WinUI 音频播放、时间显示、拖动定位；视频背景预览和循环。
- LRC 多时间戳和 SRT 字幕解析；3 / 5 句歌词容错窗口与上移淡入切换。
- 文章阅读模式、分页与中英文阅读时长估算，BGM 循环播放。
- 随应用携带的用户提供字体、英文 Cramaten 默认项、字体导入入口及授权提醒。
- Direct3D 11 / HLSL GPU 可视化后端，包含 Wave、Spectrum、Mirror、Circle、Ripple、Aurora、Prism、Nebula、Flower、Starfield 和 Border；Media Foundation 在后台解码音频与视频，64 频段 FFT 数据交给 GPU 着色器合成。
- 图片、视频背景均通过同一 Direct3D 合成器预览和渲染；视频解码在独立工作线程，避免阻塞界面刷新。
- 一键输出 9:16 / 16:9 / 1:1 MP4：1080 像素长边、30 FPS、H.264 + AAC；包含音频响应视觉效果、片头歌名/作者/日期、滚动歌词或文章页、所选字体与淡入动画。
- 导出进度覆盖音频分析与逐帧渲染，支持取消；先写入临时文件，完成后再替换目标文件，避免取消时留下不完整成片。
- Media Foundation 导出启用硬件 MFT，并传入当前 Direct3D 设备管理器以优先使用相匹配的硬件视频编码器。NVIDIA 显卡上的实际编码器选择仍取决于驱动与系统已注册的 MFT；Direct3D 可视化合成则使用应用选择的高性能显卡。

## 与 macOS 版的差异与限制

Windows 版已经具备完整的素材导入、预览和基础 MP4 生成流程，但仍未覆盖 macOS 版的全部视觉与素材功能：

- H.264 硬件编码器由 Windows Media Foundation 根据当前 Direct3D 设备和驱动选择；目前不会锁定 NVIDIA NVENC，也不保证每台电脑都使用 NVENC。
- 背景视频的可选原声可在预览播放器中开关，但本版成片仅混入主音乐；多张图片轮播、场景天气粒子、Vision 主体保护、智能调色和更多 macOS 视觉细节仍待迁移。
- 歌词和片头在最终文件中会按当前设置绘制；文章分页遵循预览的分页时序，文章行距的像素级一致性仍需在 Windows 设备上继续校准。
- 字体文件由项目提供者放入资源目录；重新分发和嵌入字体前仍须核实各自授权。用户导入字体也应拥有相应使用权。

目前打包的两款 TTF 来自项目提供者此前放入 macOS 项目的字体。许可证和再分发授权尚未独立核验；对外发布 Windows 安装包前，请先确认字体文件允许随应用再分发。用户导入的字体也只应在取得授权后用于成片。

## Windows 构建与运行

需要 Windows 11、.NET 10 SDK、Visual Studio 2022 或 Build Tools，并安装 C++ 桌面开发、Windows 11 SDK 与 .NET 桌面开发组件。

在 PowerShell 中从仓库根目录运行：

```powershell
./win11/scripts/build.ps1
./win11/scripts/run.ps1 -NoBuild
```

构建并安装到当前用户的 `AppData/Local/Programs/SikaMTV`，同时添加开始菜单快捷方式：

```powershell
./win11/scripts/install.ps1
```

发布文件位于 `win11/artifacts/publish/win-x64/`。脚本不安装驱动或更改 NVIDIA 系统设置；Windows 构建工作流还会保存一个可下载的 x64 发布产物。实际硬件编码器、预览流畅度及不同格式兼容性需在目标 Windows 电脑上核验。

## 隐私与授权

素材只在用户本机导入和处理。用户需自行确保背景、音乐和字体的使用授权。字体提示不构成法律意见。
