#!/usr/bin/env bash
# 本机 Foundation 核心数值验收，只读取合成临时文件，不访问真实 Powertools 数据。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT_DIR/CodexMeter/AntigravityPowertoolsUsage.swift"
if [[ ! -f "$CORE" ]]; then
  echo 'FAIL: 尚无 Powertools 本机用量核心实现' >&2
  exit 1
fi
WORK_DIR="$(mktemp -d /tmp/codexmeter-powertools-test.XXXXXXXX)"
# 仅清理由本脚本创建的确切普通临时目录。
cleanup() {
  if [[ "$WORK_DIR" == /tmp/codexmeter-powertools-test.* && -d "$WORK_DIR" && ! -L "$WORK_DIR" ]]; then
    local resolved
    resolved="$(cd "$WORK_DIR" && pwd -P)"
    if [[ "$resolved" == "/private$WORK_DIR" || "$resolved" == "$WORK_DIR" ]]; then rm -rf -- "$resolved"; fi
  fi
}
trap cleanup EXIT
cp "$ROOT_DIR/script/antigravity_powertools_checks.swift" "$WORK_DIR/main.swift"
case "$(uname -m)" in
  x86_64) TARGET='x86_64-apple-macosx10.15' ;;
  arm64) TARGET='arm64-apple-macosx11.0' ;;
  *) echo '不支持的测试架构' >&2; exit 1 ;;
esac
/usr/bin/xcrun swiftc -target "$TARGET" -o "$WORK_DIR/checks" "$CORE" "$WORK_DIR/main.swift"
"$WORK_DIR/checks" "$WORK_DIR"
