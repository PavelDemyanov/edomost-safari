#!/bin/bash
# Компилирует trustd (arm64) и встраивает его в переданный .app как helper,
# при наличии подписи — подписывает с hardened runtime + его entitlements.
#   embed_trustd.sh <path-to-.app> [SIGN_IDENTITY]
set -e
APP="$1"; SIGN="$2"
[ -d "$APP" ] || { echo "embed_trustd: нет .app: $APP" >&2; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS="$APP/Contents/Helpers"
mkdir -p "$HELPERS"

echo "→ Компилирую trustd (arm64)…"
clang++ -std=c++11 -arch arm64 -DUNIX -DSIZEOF_VOID_P=8 \
  -I/opt/cprocsp/include -I/opt/cprocsp/include/cpcsp \
  "$DIR/trustd.cpp" \
  -L/opt/cprocsp/lib -F/Library/Frameworks -framework CPROCSP -lcapi10 -lrdrsup -flat_namespace \
  -o "$HELPERS/trustd"

if [ -n "$SIGN" ]; then
  echo "→ Подписываю trustd (hardened runtime)…"
  TS="${CODESIGN_TIMESTAMP:---timestamp}"   # локальный тест без сети: CODESIGN_TIMESTAMP=--timestamp=none
  codesign --force "$TS" --options runtime \
    --entitlements "$DIR/trustd.entitlements" --sign "$SIGN" "$HELPERS/trustd"
fi
echo "✓ trustd встроен: $HELPERS/trustd ($(file "$HELPERS/trustd" | sed 's/.*: //'))"
