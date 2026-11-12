#!/bin/zsh
# Builds Purrlate.app. Uses xcodebuild if Xcode is installed, otherwise swiftc (Command Line Tools).
set -e
cd "$(dirname "$0")"
if xcodebuild -version >/dev/null 2>&1; then
  xcodebuild -project Purrlate.xcodeproj -scheme Purrlate -configuration Release -derivedDataPath build/dd build
  rm -rf build/Purrlate.app && cp -R build/dd/Build/Products/Release/Purrlate.app build/
else
  APP=build/Purrlate.app
  rm -rf $APP && mkdir -p $APP/Contents/MacOS
  swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macosx27.0 \
    Purrlate/*.swift -o $APP/Contents/MacOS/Purrlate
  cp Info.plist $APP/Contents/Info.plist
  mkdir -p $APP/Contents/Resources && cp -R Purrlate/*.lproj Purrlate/AppIcon.icns $APP/Contents/Resources/
  codesign --force --sign - $APP
fi
echo "Built build/Purrlate.app"
