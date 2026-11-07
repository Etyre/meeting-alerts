#!/bin/zsh
# Installs/restarts the launchd agent so Meeting Alerts runs at login and stays running.
set -e
PLIST=~/Library/LaunchAgents/com.elityre.meeting-alerts.plist
cp ~/Documents/agent-coding/meeting-alerts/com.elityre.meeting-alerts.plist "$PLIST"
launchctl bootout gui/$(id -u)/com.elityre.meeting-alerts 2>/dev/null || true
pkill -x MeetingAlerts 2>/dev/null || true   # stop any manually launched copy
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "agent started; log: ~/Library/Logs/meeting-alerts.log"
