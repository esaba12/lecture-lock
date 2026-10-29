#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=LectureLock.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
# Universal binary: Apple Silicon + Intel.
BUILD=$(mktemp -d)
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos14 Sources/*.swift -o $BUILD/LectureLock-$arch
done
lipo -create $BUILD/LectureLock-arm64 $BUILD/LectureLock-x86_64 -output $APP/Contents/MacOS/LectureLock
rm -r "$BUILD"
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>LectureLock</string>
  <key>CFBundleIdentifier</key><string>com.ethansaba.lecturelock</string>
  <key>CFBundleExecutable</key><string>LectureLock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppleEventsUsageDescription</key><string>LectureLock keeps your browser on the lecture tab.</string>
</dict></plist>
PLIST
codesign --force -s - $APP
echo "Built $PWD/$APP"

# ./build.sh --install: replace /Applications/LectureLock.app with this build and relaunch it.
if [[ "$1" == --install ]]; then
  if defaults read com.ethansaba.lecturelock activeLock &>/dev/null; then
    echo "A lock is running. Install again once it's over." >&2
    exit 1
  fi
  osascript -e 'tell application id "com.ethansaba.lecturelock" to quit' 2>/dev/null || true
  for i in {1..20}; do pgrep -xq LectureLock || break; sleep 0.5; done
  if pgrep -xq LectureLock; then
    echo "LectureLock didn't quit. Quit it from the menu bar and try again." >&2
    exit 1
  fi
  rm -rf /Applications/$APP
  cp -R $APP /Applications/
  open /Applications/$APP
  echo "Installed /Applications/$APP"
fi
