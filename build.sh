#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=LectureLock.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
swiftc -O -parse-as-library main.swift -o $APP/Contents/MacOS/LectureLock
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
