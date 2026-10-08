#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=LectureLock.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
# Universal binary: Apple Silicon + Intel.
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos14 main.swift -o /tmp/LectureLock-$arch
done
lipo -create /tmp/LectureLock-arm64 /tmp/LectureLock-x86_64 -output $APP/Contents/MacOS/LectureLock
rm /tmp/LectureLock-arm64 /tmp/LectureLock-x86_64
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>LectureLock</string>
  <key>CFBundleIdentifier</key><string>com.ethansaba.lecturelock</string>
  <key>CFBundleExecutable</key><string>LectureLock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppleEventsUsageDescription</key><string>LectureLock keeps your browser on the lecture tab.</string>
</dict></plist>
PLIST
codesign --force -s - $APP
echo "Built $PWD/$APP"
