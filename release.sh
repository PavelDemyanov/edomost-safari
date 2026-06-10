#!/bin/bash
# release.sh — сборка публичного дистрибутива «ЭДО Мост для Safari»:
#   Developer ID подпись -> нотаризация -> stapler -> .dmg для раздачи с сайта.
#
# ПРЕДВАРИТЕЛЬНО (один раз):
#   1) Создать сертификат Developer ID Application:
#        Xcode -> Settings -> Accounts -> ваша команда -> Manage Certificates… -> + -> Developer ID Application
#   2) Сохранить креды для нотаризации (пароль попросит интерактивно, мне его показывать не нужно):
#        xcrun notarytool store-credentials "edomost-notary" \
#            --apple-id "ВАШ_APPLE_ID@почта" --team-id "V6KX6679UL"
#      (app-specific password создаётся на appleid.apple.com -> «Вход и безопасность»)
#
# Затем просто:  ./release.sh

set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

ROOT="$HOME/Developer/MoeDeloSafariBridge"
XCPROJ="$ROOT/xcode/MoeDeloBridge/MoeDeloBridge.xcodeproj"
DD="$ROOT/DerivedData-release"
OUT="$ROOT/dist"
APP_NAME="ЭДО Мост для Safari"
KEYCHAIN_PROFILE="edomost-notary"

mkdir -p "$OUT"
rm -rf "$DD"

# --- 1. Найти Developer ID Application сертификат ---------------------------
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
          | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -z "$SIGN_ID" ]; then
  echo "❌ Нет сертификата «Developer ID Application» в связке."
  echo "   Создайте его: Xcode → Settings → Accounts → команда → Manage Certificates… → + → Developer ID Application"
  exit 1
fi
echo "🔏 Подпись: $SIGN_ID"

# --- 2. Сборка Release с Developer ID + hardened runtime -------------------
echo "🔨 Сборка…"
xcodebuild -project "$XCPROJ" -scheme "MoeDeloBridge" -configuration Release \
  -derivedDataPath "$DD" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_ID" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  build > "$ROOT/build-release.log" 2>&1 \
  || { echo "❌ Сборка упала, см. $ROOT/build-release.log"; tail -20 "$ROOT/build-release.log"; exit 1; }

BUILT="$DD/Build/Products/Release/MoeDeloBridge.app"
echo "✅ Собрано: $BUILT"

# --- 2b. Пере-подпись с ЯВНЫМИ entitlements. Подписываем изнутри наружу:
#   • расширение ОБЯЗАНО быть в песочнице (app-sandbox + network.client),
#     иначе macOS молча отказывается его регистрировать;
#   • приложение — БЕЗ песочницы: фоновому режиму плагина нужны launchctl,
#     остановка чужих процессов и запись в ~/Library/LaunchAgents.
ENT="$ROOT/sandbox.entitlements"
echo "🔏 Пере-подпись (расширение: песочница; приложение: без)…"
codesign --force --timestamp --options runtime --entitlements "$ENT" --sign "$SIGN_ID" "$BUILT/Contents/PlugIns/MoeDeloBridge Extension.appex"
codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$BUILT"
echo "  entitlements расширения после пере-подписи:"
codesign -d --entitlements - "$BUILT/Contents/PlugIns/MoeDeloBridge Extension.appex" 2>/dev/null | grep -iE "sandbox|network.client" | sed 's/^/    /'

# --- 3. Проверка подписи (sandbox/hardened/без get-task-allow) -------------
codesign --verify --deep --strict "$BUILT"
APPEX="$BUILT/Contents/PlugIns/MoeDeloBridge Extension.appex"
if codesign -d --entitlements - "$APPEX" 2>/dev/null | grep -q "get-task-allow.*true\|get-task-allow</key>"; then
  echo "⚠️  В расширении остался get-task-allow — нотаризация может отклонить."
fi

# --- 4. Подготовить .app с красивым именем --------------------------------
WORK="$(mktemp -d)"
APP="$WORK/$APP_NAME.app"
cp -R "$BUILT" "$APP"

HAVE_NOTARY=0
if xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  HAVE_NOTARY=1
fi

# --- 5. Нотаризовать и пришить тикет к .app (офлайн-устойчиво) -------------
if [ "$HAVE_NOTARY" = "1" ]; then
  echo "🍏 Нотаризация приложения (ждём вердикт Apple)…"
  ZIP="$WORK/app.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

# --- 6. Собрать DMG из (заверенного) приложения ----------------------------
DMG="$OUT/$APP_NAME.dmg"
rm -f "$DMG"
STAGING="$WORK/dmg"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
echo "📦 DMG…"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
echo "✅ DMG: $DMG"

# --- 7. Нотаризовать и пришить тикет к DMG ---------------------------------
if [ "$HAVE_NOTARY" = "1" ]; then
  echo "🍏 Нотаризация DMG…"
  xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG" && echo "✅ DMG нотаризован и заверён."
  hdiutil attach "$DMG" -nobrowse -mountpoint "$WORK/mnt" >/dev/null 2>&1 \
    && { echo "🔎 Проверка приложения внутри:"; spctl -a -vvv "$WORK/mnt/$APP_NAME.app" 2>&1 | head -3; \
         xcrun stapler validate "$WORK/mnt/$APP_NAME.app" 2>&1 | tail -1; \
         hdiutil detach "$WORK/mnt" >/dev/null 2>&1; }
else
  echo "⚠️  Профиль «$KEYCHAIN_PROFILE» не настроен — DMG собран, но НЕ нотаризован."
  echo "     xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" --apple-id \"ВАШ_APPLE_ID\" --team-id \"V6KX6679UL\""
fi

rm -rf "$WORK"
echo ""
echo "Готово: $DMG"
