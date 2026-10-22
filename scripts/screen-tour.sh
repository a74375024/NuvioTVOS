#!/usr/bin/env bash
# Builds the app for the tvOS simulator, opens a set of screens as a guest
# (via the -NuvioScreenTour launch argument) and saves a screenshot of each to
# ./screens. Run from the repo root after `tuist generate` (build-ipa.sh does it).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT_DIR/screens"
DD="${TMPDIR:-/tmp}/NuvioTV-ScreenTour"
rm -rf "$OUT"; mkdir -p "$OUT"

udid=$(xcrun simctl list devices available --json | ruby -rjson -e '
  devices = JSON.parse(STDIN.read).fetch("devices").select { |rt, _| rt.include?(".tvOS-") }.values.flatten
  device = devices.find { |d| d["name"] =~ /4K/ && d["name"] !~ /1st/ } || devices.first
  abort "No tvOS simulator available" unless device
  puts device.fetch("udid")
')
echo "==> Simulator $udid"
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b

echo "==> Building for the simulator..."
xcodebuild build \
  -workspace "$ROOT_DIR/tvosApp/NuvioTV.xcworkspace" \
  -scheme NuvioTV -configuration Debug \
  -destination "platform=tvOS Simulator,id=$udid" \
  -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES -quiet

app=$(find "$DD/Build/Products" -maxdepth 2 -name 'NuvioTV.app' -path '*simulator*' | head -1)
[ -d "$app" ] || { echo "Simulator app not found" >&2; exit 1; }
bundle=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist")
xcrun simctl install "$udid" "$app"
echo "==> Installed $bundle"

# name | tour target | seconds to wait before the screenshot
shots=(
  "01-home|home|20"
  "02-channels-guide|channels|25"
  "03-channels-trailer|channels|45"
  "04-calendar|calendar|20"
  "05-show-page-shuffle|details:tt0386676:series|20"
  "06-live-tv-empty|live|12"
  "07-live-tv-guide|live-demo|12"
  "08-settings|settings|12"
)

for entry in "${shots[@]}"; do
  IFS='|' read -r name target wait <<<"$entry"
  echo "==> $name ($target, ${wait}s)"
  xcrun simctl launch --terminate-running-process "$udid" "$bundle" -NuvioScreenTour "$target" >/dev/null || true
  sleep "$wait"
  xcrun simctl io "$udid" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1 || echo "  (screenshot failed)"
done

xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
(cd "$OUT" && zip -q screens.zip ./*.png)
ls -lh "$OUT"
