#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SikaMTV"
PRODUCT_NAME="MTVMusicVideo"
CONFIGURATION="release"
OPEN_AFTER_BUILD="false"
INSTALL_TO_APPLICATIONS="false"
APP_VERSION="${APP_VERSION:-1.0.0}"

usage() {
    cat <<'USAGE'
用法：
  ./scripts/package_app.sh [选项]

选项：
  --debug      使用 Debug 构建
  --open       打包完成后打开 App
  --install    打包完成后复制到 /Applications
  --version X  设置 App 版本号，默认 1.0.0
  -h, --help   显示帮助
USAGE
}

while (($# > 0)); do
    case "$1" in
        --debug)
            CONFIGURATION="debug"
            ;;
        --open)
            OPEN_AFTER_BUILD="true"
            ;;
        --install)
            INSTALL_TO_APPLICATIONS="true"
            ;;
        --version)
            shift
            if (($# == 0)); then
                echo "缺少 --version 的参数" >&2
                exit 2
            fi
            APP_VERSION="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知选项：$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

cd "$PROJECT_ROOT"

echo "正在构建 ${APP_NAME} (${CONFIGURATION})..."
swift build --configuration "$CONFIGURATION"
BIN_PATH="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
EXECUTABLE_PATH="$BIN_PATH/$PRODUCT_NAME"
if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "找不到构建产物：$EXECUTABLE_PATH" >&2
    exit 1
fi

DIST_DIR="$PROJECT_ROOT/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
CONTENTS_PATH="$APP_PATH/Contents"

rm -rf "$APP_PATH"
mkdir -p "$CONTENTS_PATH/MacOS" "$CONTENTS_PATH/Resources"
cp "$EXECUTABLE_PATH" "$CONTENTS_PATH/MacOS/$PRODUCT_NAME"
cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS_PATH/Info.plist"
mkdir -p "$CONTENTS_PATH/Resources/Fonts"
cp "$PROJECT_ROOT/Sources/MTVMusicVideo/Resources/Fonts/SikaDefault.ttf" "$CONTENTS_PATH/Resources/Fonts/SikaDefault.ttf"

# Build a complete macOS icon set from the source PNG. The asset catalog is kept
# in a temporary directory so packaging never depends on generated files in the repo.
ICON_SOURCE="$PROJECT_ROOT/Resources/mtv.png"
ASSET_BUILD_DIR="$(mktemp -d /tmp/mtv-assets.XXXXXX)"
trap 'rm -rf "$ASSET_BUILD_DIR"' EXIT
ICONSET_DIR="$ASSET_BUILD_DIR/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET_DIR"
cp "$PROJECT_ROOT/Resources/Assets.xcassets/Contents.json" "$ASSET_BUILD_DIR/Assets.xcassets/Contents.json"
cp "$PROJECT_ROOT/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json" "$ICONSET_DIR/Contents.json"
sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
mkdir -p "$ASSET_BUILD_DIR/compiled"
actool --compile "$ASSET_BUILD_DIR/compiled" --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon --output-partial-info-plist "$ASSET_BUILD_DIR/partial.plist" "$ASSET_BUILD_DIR/Assets.xcassets" >/dev/null
cp "$ASSET_BUILD_DIR/compiled/AppIcon.icns" "$CONTENTS_PATH/Resources/AppIcon.icns"
cp "$ASSET_BUILD_DIR/compiled/Assets.car" "$CONTENTS_PATH/Resources/Assets.car"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$CONTENTS_PATH/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$CONTENTS_PATH/Info.plist"

# Ad-hoc 签名足够让本地双击启动；正式分发时替换为开发者证书签名和公证流程。
codesign --force --deep --sign - "$APP_PATH" >/dev/null

if [[ "$INSTALL_TO_APPLICATIONS" == "true" ]]; then
    DESTINATION="/Applications/$APP_NAME.app"
    rm -rf "$DESTINATION"
    cp -R "$APP_PATH" "$DESTINATION"
    APP_PATH="$DESTINATION"
fi

echo "App 已生成：$APP_PATH"
echo "可以双击打开，或运行：open \"$APP_PATH\""

if [[ "$OPEN_AFTER_BUILD" == "true" ]]; then
    open "$APP_PATH"
fi
