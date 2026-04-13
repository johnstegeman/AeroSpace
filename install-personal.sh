#!/bin/bash
# Personal install script — builds and installs AeroSpace.app to /Applications.
# Uses ad-hoc codesigning (no certificate needed).
# To auto-start on login, set start-at-login = true in your aerospace config.
cd "$(dirname "$0")"
source ./script/setup.sh

set -e

echo "==> Syncing jj working copy to git..."
/opt/homebrew/bin/jj git export

echo "==> Generating Xcode project (ad-hoc signing)..."
./generate.sh --ignore-cmd-help --ignore-shell-parser --codesign-identity -

echo "==> Building CLI..."
swift build -c release --product aerospace

echo "==> Cleaning previous build artifacts..."
rm -rf .xcode-build

echo "==> Building AeroSpace.app..."
xcodebuild-pretty /tmp/aerospace-install.log build \
    -scheme AeroSpace \
    -destination "generic/platform=macOS" \
    -configuration Release \
    -derivedDataPath .xcode-build

APP_SRC=".xcode-build/Build/Products/Release/AeroSpace.app"
CLI_SRC=".build/release/aerospace"

if [ ! -d "$APP_SRC" ]; then
    echo "Error: app bundle not found at $APP_SRC" >&2
    exit 1
fi

echo "==> Installing to /Applications and /usr/local/bin..."
rm -rf /Applications/AeroSpace.app
cp -r "$APP_SRC" /Applications/AeroSpace.app

mkdir -p /usr/local/bin
sudo cp "$CLI_SRC" /usr/local/bin/aerospace
sudo codesign -s - /usr/local/bin/aerospace

echo ""
echo "Installed:"
echo "  /Applications/AeroSpace.app"
echo "  /usr/local/bin/aerospace"
echo ""
echo "To start on login, add to ~/.config/aerospace/aerospace.toml:"
echo "  start-at-login = true"
echo ""
echo ""
echo "Installed:"
echo "  /Applications/AeroSpace.app"
echo "  /usr/local/bin/aerospace"
