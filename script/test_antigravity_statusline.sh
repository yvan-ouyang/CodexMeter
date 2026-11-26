#!/usr/bin/env bash
# 在缺少完整 Xcode 时，用实际系统 Swift 编译并执行 Statusline 核心验收；仅使用合成数据和临时目录。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT_DIR/CodexMeter/AntigravityStatusline.swift"
if [[ ! -f "$CORE" ]]; then
  echo 'FAIL: 尚无 Antigravity Statusline 核心实现' >&2
  exit 1
fi
WORK_DIR="$(mktemp -d /tmp/codexmeter-statusline-test.XXXXXXXX)"
# 只清理本脚本刚创建的、带固定前缀的临时目录。
cleanup() {
  if [[ "$WORK_DIR" == /tmp/codexmeter-statusline-test.* && -d "$WORK_DIR" && ! -L "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT
cp "$ROOT_DIR/script/antigravity_statusline_checks.swift" "$WORK_DIR/main.swift"
case "$(uname -m)" in
  x86_64) TARGET='x86_64-apple-macosx10.15' ;;
  arm64) TARGET='arm64-apple-macosx11.0' ;;
  *) echo '不支持的测试架构' >&2; exit 1 ;;
esac
/usr/bin/xcrun swiftc -target "$TARGET" -o "$WORK_DIR/checks" "$CORE" "$WORK_DIR/main.swift"
"$WORK_DIR/checks" "$WORK_DIR"
