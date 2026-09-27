# SikaMTV for Windows 11

Windows 客户端使用 WinUI 3 / Windows App SDK 构建原生桌面界面；Direct3D 11 后端会枚举高性能显卡并优先选择 NVIDIA 适配器。图形效果由 HLSL 像素着色器在 GPU 上合成。无 NVIDIA 显卡时，图形设备会回退到系统可用的硬件适配器。

## 当前已实现

- 三栏原生桌面工作区：素材库、比例匹配的预览、分组参数和项目素材槽。
- 图片 / 视频、音频、LRC / SRT / TXT / Markdown 导入，素材库搜索，以及将素材明确加入工作区。
- WinUI 音频播放、时间显示、拖动定位；视频背景预览和循环。
- LRC 多时间戳和 SRT 字幕解析；3 / 5 句歌词容错窗口与上移淡入切换。
- 文章阅读模式、分页与中英文阅读时长估算，BGM 循环播放。
- 应用携带中文与英文默认字体，支持导入并保留用户的 TTF / OTF 字体，以及字体授权提醒。
- Direct3D 11 / HLSL GPU 可视化后端，包含 Wave、Spectrum、Mirror、Circle、Ripple、Aurora、Prism、Nebula、Kaleidoscope、Starfield 和 Border；Media Foundation 在后台解码音频与视频，64 频段 FFT 数据交给 GPU 着色器合成。
- 图片与视频可混合加入背景轮播，按音频时长平均分配区间；支持淡入淡出、滑动、缩放叠化和直接切换，单视频循环与背景视频原声开关。预览和导出共用轮播时间轴、D3D 合成器与背景调色。
- 支持 16 种人工选择的音乐场景氛围、背景颜色分析、静态图慢速运镜、人脸/显著主体保护与智能模糊；图片分析结果缓存在本机，逐帧渲染不会重新分析。
- 一键输出 9:16 / 16:9 / 1:1 MP4：1080 像素长边、30 FPS、H.264 + AAC；包含可关闭的歌名/作者/日期片头、可调歌词动画、滚动歌词或文章页及所选字体。
- 导出进度覆盖音频分析与逐帧渲染，支持取消；先写入临时文件，完成后再替换目标文件，避免取消时留下不完整成片。
- Media Foundation 导出启用硬件 MFT，并传入当前 Direct3D 设备管理器以优先使用相匹配的硬件视频编码器。NVIDIA 显卡上的实际编码器选择仍取决于驱动与系统已注册的 MFT；Direct3D 可视化合成则使用应用选择的高性能显卡。

## 与 macOS 版的对齐状态

Windows 版已对齐主要创作流程和可见设置：素材库与项目槽、LRC/SRT/文章阅读、字体导入、5 套模板、11 种可视化、16 种场景氛围、多背景轮播、标题片头、比例预览和可取消导出。由于两个版本分别使用原生图形、文字与媒体框架，仍需继续收敛以下差异：

- 音乐分析目前为 64 频段；macOS 版还包含更高分辨率频谱、Chroma/调性与乐曲段落特征。Windows 可视化目前按频谱能量响应，音乐结构理解仍需继续对齐。
- macOS 使用 Vision 的主体分割与显著性分析；Windows 使用本机人脸检测和显著性遮罩作为对应实现，主体识别精度不会完全相同。
- GPU 背景、氛围和可视化由同一 HLSL 着色器用于预览与导出；歌词/片头预览由 WinUI 绘制，导出由原生文字合成器绘制，复杂字体换行等细节仍需在 Windows 真机继续校准。
- H.264 硬件编码器由 Windows Media Foundation 根据当前 Direct3D 设备和驱动选择；不会锁定 NVIDIA NVENC，也不保证每台电脑都使用 NVENC。画面合成会优先使用 NVIDIA GPU，缺少 NVIDIA 时回退到其他硬件 Direct3D 适配器。
- Windows 的 16 种氛围预置共用 GPU 程序化场景层；雨、雪、叶片、花瓣、水面、雾气等均已实现，但粒子材质和场景细节还没有达到 macOS Metal 氛围引擎的逐项一致。
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
