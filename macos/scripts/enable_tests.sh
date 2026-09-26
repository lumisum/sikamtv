#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "正在启用并运行 MTVMusicVideo 测试目标…"
swift test "$@"
echo "测试完成。"
