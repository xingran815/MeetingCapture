#!/usr/bin/env bash
# Builds MeetingCapture.app from the SwiftPM target MeetingCaptureDesktop.
#
# SwiftPM builds the binary; this wraps it in a bundle with packaging/Info.plist, so the
# Microphone and Screen & System Audio Recording permissions belong to the app itself.
#
#   scripts/build-app.sh             → .build/MeetingCapture.app
#   scripts/build-app.sh --install   → also copies it to ~/Applications
#
# Signing: an "Apple Development" identity in the keychain if there is one, because
# macOS keys permissions to the signature and an ad-hoc one changes on every build
# (so the permissions would be asked again). Otherwise ad-hoc, which is enough for
# personal use. Handing the app to anyone else would need a Developer ID and notarization.
# MC_SIGN_IDENTITY overrides the choice; "-" forces ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

install=0
[[ "${1:-}" == "--install" ]] && install=1

swift build -c release --product MeetingCaptureDesktop
bin=".build/release/MeetingCaptureDesktop"
[[ -x "$bin" ]] || { echo "build-app: no binary at $bin" >&2; exit 1; }

app=".build/MeetingCapture.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/MeetingCapture"
cp packaging/Info.plist "$app/Contents/Info.plist"
[[ -f packaging/AppIcon.icns ]] && cp packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns" \
    && /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist"
# WhisperKit and SpeakerKit ship no resource bundles we need; models download at first run.

identity="${MC_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    found="$(security find-identity -v -p codesigning 2>/dev/null)"
    identity="$(printf '%s\n' "$found" | awk '/"Apple Development/ {print $2; exit}')"
    [[ -n "$identity" ]] || identity="-"
fi
# The identity's name holds an email, so only say which kind was used.
if [[ "$identity" == "-" ]]; then kind="ad-hoc"; else kind="Apple Development"; fi
codesign --force --sign "$identity" --identifier com.meetingcapture.desktop "$app" >/dev/null 2>&1 \
    || { echo "build-app: signing failed ($kind)" >&2; exit 1; }
codesign --verify "$app"
echo "build-app: $app (signed $kind)"

if (( install )); then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/MeetingCapture.app"
    cp -R "$app" "$HOME/Applications/MeetingCapture.app"
    echo "build-app: installed to ~/Applications/MeetingCapture.app"
fi
