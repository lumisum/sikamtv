# 本地脚本

## 打包成正常 macOS App

在项目根目录运行：

```bash
./scripts/package_app.sh --open
```

生成结果位于：

```text
dist/SikaMTV.app
```

也可以直接安装到 `/Applications`：

```bash
./scripts/package_app.sh --install --open
```

开发调试版本：

```bash
./scripts/package_app.sh --debug --open
```

正式对外发布前，还需要使用 Apple Developer 证书签名并完成 notarization。当前脚本使用 ad-hoc 签名，适合本机开发和本地使用。

App 图标来源于 `Resources/mtv.png`。打包时脚本会自动生成多尺寸 `AppIcon.icns` 和 `Assets.car`，如果替换了 PNG，重新运行打包脚本即可更新图标。

## 启用并运行测试

```bash
./scripts/enable_tests.sh
```

脚本会执行 Swift Package 的测试目标，也支持把参数继续传给 `swift test`：

```bash
./scripts/enable_tests.sh --filter LRCParserTests
```
