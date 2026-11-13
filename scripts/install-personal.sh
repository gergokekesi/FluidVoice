#!/bin/bash
# Signs with the Apple Development certificate so macOS keeps Accessibility, Microphone and Screen Recording across rebuilds.
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

identity="$(security find-identity -v -p codesigning | sed -n 's/.* \([[:xdigit:]]\{40\}\) "Apple Development:.*/\1/p' | head -1)"
if [ -z "$identity" ]; then
    echo "No valid Apple Development certificate (Xcode > Settings > Apple Accounts > Personal Team > Manage Certificates)." >&2
    exit 1
fi

log="$(mktemp -t fluidvoice-build)"
echo "Building Release, log in $log"
if ! xcodebuild build -project Fluid.xcodeproj -scheme Fluid -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath DerivedData \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= >"$log" 2>&1; then
    grep -E "error:" "$log" | head -20 >&2
    exit 1
fi

app=DerivedData/Build/Products/Release/FluidVoice.app
transcribe="$app/Contents/Frameworks/CTranscribe.framework"
relink() { rm -rf "$1"; ln -s "$2" "$1"; }
relink "$transcribe/Versions/Current" A
relink "$transcribe/CTranscribe" Versions/Current/CTranscribe
relink "$transcribe/Resources" Versions/Current/Resources

sign() { codesign --force --sign "$identity" --options runtime --timestamp=none "$@"; }
for framework in "$app"/Contents/Frameworks/*.framework; do
    sign --preserve-metadata=identifier,flags "$framework"
done
sign --preserve-metadata=identifier,entitlements,flags "$app/Contents/Helpers/fv-serve"
entitlements="$(mktemp -t fluidvoice-entitlements)"
codesign --display --entitlements :- "$app" >"$entitlements" 2>/dev/null
sign --preserve-metadata=identifier,flags --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"

osascript -e 'quit app "FluidVoice"' || true
for _ in $(seq 1 30); do pgrep -x FluidVoice >/dev/null || break; sleep 0.5; done
rm -rf /Applications/FluidVoice.app
ditto "$app" /Applications/FluidVoice.app
open -a /Applications/FluidVoice.app
