#!/bin/bash
# Validate actual package contents, architecture and signing. No network in local mode.
set -euo pipefail
app="${1:?提供 .app 路径}"
mode="${2:-local}"
[[ "$mode" == local || "$mode" == release ]] || { echo '未知校验模式' >&2; exit 1; }
plist="$app/Contents/Info.plist"
plutil -lint "$plist" >/dev/null
[[ "$(plutil -extract CFBundleIdentifier raw "$plist")" == com.deepseekisland.app ]] || { echo 'Bundle ID 不匹配' >&2; exit 1; }
[[ -s "$app/Contents/Resources/AppIcon.icns" && -d "$app/Contents/Resources/AIUsageIsland_DeepSeekIsland.bundle" ]] || { echo '缺少必要资源' >&2; exit 1; }
for resource in AppLogo.png ChatGPTLogo.png CodingPlanLogo.png DeepSeekLogo.svg; do
    [[ -s "$app/Contents/Resources/AIUsageIsland_DeepSeekIsland.bundle/$resource" ]] || { echo "缺少资源：$resource" >&2; exit 1; }
done
[[ "$(lipo -archs "$app/Contents/MacOS/AIUsageIsland")" == arm64 ]] || { echo '当前产物要求 arm64' >&2; exit 1; }
codesign --verify --strict "$app"
if [[ "$mode" == release ]]; then
    details="$(codesign -dv --verbose=4 "$app" 2>&1)"
    [[ "$details" == *'Authority=Developer ID Application:'* && "$details" == *'(runtime)'* ]] || { echo '缺少正式身份或 Hardened Runtime' >&2; exit 1; }
    xcrun stapler validate "$app"
    spctl --assess --type execute "$app"
fi
version="$(plutil -extract CFBundleShortVersionString raw "$plist")"
build="$(plutil -extract CFBundleVersion raw "$plist")"
echo "校验通过：$version ($build)，arm64，$mode"
