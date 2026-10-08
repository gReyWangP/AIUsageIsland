#!/bin/bash
# Local test packages by default. Release mode requires explicit Developer ID and notary profile.
# Usage: ./scripts/build-app.sh [output-directory] [--mode local|release]
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
output_dir="$root/dist"
mode="local"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) [[ $# -ge 2 ]] || { echo '缺少 --mode 参数' >&2; exit 1; }; mode="$2"; shift 2 ;;
        --*) echo "未知参数：$1" >&2; exit 1 ;;
        *) output_dir="$1"; shift ;;
    esac
done
[[ "$mode" == local || "$mode" == release ]] || { echo '模式必须为 local 或 release' >&2; exit 1; }
[[ -f "$root/Resources/AppIcon.icns" ]] || { echo '缺少 Resources/AppIcon.icns，保留已有产物' >&2; exit 1; }
plutil -lint "$root/Info.plist" >/dev/null
version="$(plutil -extract CFBundleShortVersionString raw "$root/Info.plist")"
build="$(plutil -extract CFBundleVersion raw "$root/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || { echo '版本或构建号格式错误' >&2; exit 1; }
identity="${SIGNING_IDENTITY:-}"
notary_profile="${NOTARY_KEYCHAIN_PROFILE:-}"
if [[ "$mode" == release ]]; then
    [[ -n "$identity" && "$identity" != '-' && -n "$notary_profile" ]] || {
        echo '正式模式需要 SIGNING_IDENTITY 和 NOTARY_KEYCHAIN_PROFILE；不会回退临时签名' >&2; exit 1;
    }
    security find-identity -v -p codesigning | grep 'Developer ID Application:' | grep -F -- "$identity" >/dev/null || {
        echo '未找到指定的有效 Developer ID Application 身份' >&2; exit 1;
    }
fi

echo "==> 编译 $version ($build)，模式 ${mode}，架构 arm64"
swift build -c release --arch arm64
bin_path="$(swift build -c release --arch arm64 --show-bin-path)"
resource_bundle="$bin_path/AIUsageIsland_DeepSeekIsland.bundle"
[[ -d "$resource_bundle" ]] || { echo '缺少 SwiftPM 资源包，保留已有产物' >&2; exit 1; }
[[ -f "$bin_path/AIUsageIsland" ]] || { echo '缺少可执行文件，保留已有产物' >&2; exit 1; }
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
staging_dir="$(mktemp -d "$output_dir/.AIUsageIsland-build.XXXXXX")"
app="$output_dir/AIUsageIsland.app"
staged="$staging_dir/AIUsageIsland.app"
previous="$staging_dir/previous.app"
cleanup() {
    if [[ (-e "$previous" || -L "$previous") && ! -e "$app" && ! -L "$app" ]]; then mv "$previous" "$app"; fi
    rm -rf "$staging_dir"
}
trap cleanup EXIT
mkdir -p "$staged/Contents/MacOS" "$staged/Contents/Resources"
cp "$bin_path/AIUsageIsland" "$staged/Contents/MacOS/AIUsageIsland"
cp "$root/Info.plist" "$staged/Contents/Info.plist"
printf 'APPL????' > "$staged/Contents/PkgInfo"
cp "$root/Resources/AppIcon.icns" "$staged/Contents/Resources/AppIcon.icns"
cp -R "$resource_bundle" "$staged/Contents/Resources/"
if [[ "$mode" == release ]]; then
    codesign --force --sign "$identity" --options runtime --timestamp "$staged"
    ditto -c -k --keepParent "$staged" "$staging_dir/notarization.zip"
    xcrun notarytool submit "$staging_dir/notarization.zip" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$staged"
else
    codesign --force --sign - "$staged"
fi
"$root/scripts/validate-app.sh" "$staged" "$mode"
if [[ -e "$app" || -L "$app" ]]; then mv "$app" "$previous"; fi
mv "$staged" "$app"
echo "完成：$app · $version ($build) · $mode"
