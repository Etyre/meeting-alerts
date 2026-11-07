#!/bin/zsh
# Rebuilds Meeting Alerts.app in ~/Applications. Run install.sh afterwards to (re)start the launchd agent.
set -e
SRC=~/Documents/agent-coding/meeting-alerts
APP=~/Applications/"Meeting Alerts.app"
mkdir -p "$APP/Contents/MacOS"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -framework EventKit -framework UserNotifications \
  "$SRC/main.swift" -o "$APP/Contents/MacOS/MeetingAlerts"
codesign --force --sign - --identifier com.elityre.meeting-alerts "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "built and signed: $APP"
