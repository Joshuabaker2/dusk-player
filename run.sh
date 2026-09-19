#!/usr/bin/env bash
# Build and launch Dusk.
#
#   ./run.sh [mac|ios|tvos]
#
#   mac   (default) the iOS app running natively on this Mac ("Designed for iPad").
#         Needs a signing team: DEVELOPMENT_TEAM=XXXXXXXXXX ./run.sh mac
#   ios   an iPhone simulator (DEVICE="iPad Pro 13-inch (M5)" to pick another).
#   tvos  an Apple TV simulator (DEVICE="Apple TV 4K (3rd generation)" etc.).
#
# Environment:
#   DEVICE          simulator name to use instead of the first available one
#   CONFIGURATION   Debug (default) or Release
#   DEVELOPMENT_TEAM  Apple team ID; required for `mac`, ignored by simulators
#
# Builds land in build/DerivedData (git-ignored).
set -euo pipefail

cd "$(dirname "$0")"

TARGET="${1:-mac}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="build/DerivedData"
BUNDLE_ID="com.dusk-player.app"

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

case "$TARGET" in
    mac|ios) PLATFORM="iOS"; SCHEME="Dusk" ;;
    tvos) PLATFORM="tvOS"; SCHEME="Dusk-tvOS" ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown target '$TARGET' (expected mac, ios, or tvos)" ;;
esac

if [[ "$TARGET" == mac && -z "${DEVELOPMENT_TEAM:-}" ]]; then
    die "running on the Mac needs a signing team.
List yours with:  security find-identity -v -p codesigning
Then run:         DEVELOPMENT_TEAM=<team id> ./run.sh mac"
fi

# VLCKit binaries are git-ignored; the script is a no-op once they are present.
step "Checking VLCKit"
./ci_scripts/install_vlckit.sh >/dev/null

# Building for iOS or tvOS (including the Mac "Designed for iPad" variant)
# needs the platform's runtime, which Xcode does not install by default.
runtime_available() {
    xcrun simctl list runtimes -j | python3 -c '
import json, sys
platform = sys.argv[1]
runtimes = json.load(sys.stdin)["runtimes"]
sys.exit(0 if any(r.get("platform") == platform and r.get("isAvailable") for r in runtimes) else 1)
' "$1"
}

if ! runtime_available "$PLATFORM"; then
    step "Installing the $PLATFORM platform (one-time, several GB)"
    xcodebuild -downloadPlatform "$PLATFORM"
fi

# Prints the UDID of the simulator to use, creating one if none exists.
simulator_udid() {
    xcrun simctl list -j | python3 -c '
import json, subprocess, sys
platform, wanted = sys.argv[1], sys.argv[2]
family = "iPhone" if platform == "iOS" else "Apple TV"
data = json.load(sys.stdin)

runtimes = [r for r in data["runtimes"] if r.get("platform") == platform and r.get("isAvailable")]
runtime_ids = {r["identifier"] for r in runtimes}
devices = [
    d for runtime, ds in data["devices"].items() if runtime in runtime_ids
    for d in ds if d.get("isAvailable")
]

if wanted:
    matches = [d for d in devices if d["name"] == wanted]
    if not matches:
        sys.exit(f"no available simulator named {wanted!r}")
else:
    matches = [d for d in devices if d["name"].startswith(family)]

if matches:
    # Prefer one that is already running.
    matches.sort(key=lambda d: d["state"] != "Booted")
    print(matches[0]["udid"])
    sys.exit(0)

device_types = [t for t in data["devicetypes"] if t["name"].startswith(family)]
if not device_types:
    sys.exit(f"no {family} simulator device types installed")
runtime = sorted(runtimes, key=lambda r: r["version"])[-1]["identifier"]
device_type = device_types[-1]
name = device_type["name"]
print(f"Creating simulator {name}", file=sys.stderr)
print(subprocess.check_output(
    ["xcrun", "simctl", "create", device_type["name"], device_type["identifier"], runtime],
    text=True,
).strip())
' "$1" "${DEVICE:-}"
}

build() {
    xcodebuild \
        -project Dusk.xcodeproj \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -quiet \
        "$@" \
        build
}

app_path() {
    local products="$DERIVED_DATA/Build/Products/$CONFIGURATION-$1"
    local app
    app=$(find "$products" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null)
    [[ -n "$app" ]] || die "no .app found in $products"
    echo "$app"
}

run_on_simulator() {
    local sdk="$1"
    local udid
    udid=$(simulator_udid "$PLATFORM")

    step "Building $SCHEME for the $PLATFORM Simulator"
    # The vendored VLCKit is thinned to arm64, so never build the x86_64 slice.
    build -destination "id=$udid" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES

    step "Booting simulator"
    xcrun simctl bootstatus "$udid" -b >/dev/null
    open -a Simulator --args -CurrentDeviceUDID "$udid"

    step "Installing and launching"
    xcrun simctl install "$udid" "$(app_path "$sdk")"
    xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID"
}

run_on_mac() {
    step "Building $SCHEME for Mac (Designed for iPad)"
    build \
        -destination 'platform=macOS,arch=arm64,variant=Designed for iPad' \
        -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"

    local app
    app=$(app_path iphoneos)
    step "Launching $app"
    # Quit a running copy first so the fresh build is the one that opens.
    osascript -e "if application id \"$BUNDLE_ID\" is running then tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    open "$app"
}

case "$TARGET" in
    mac) run_on_mac ;;
    ios) run_on_simulator iphonesimulator ;;
    tvos) run_on_simulator appletvsimulator ;;
esac
