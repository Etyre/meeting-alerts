# Meeting Alerts

A tiny native macOS app that posts a notification 10 minutes before every timed event on
chosen calendars, keeps it on screen with a title that counts down ("Standup in 7 min"), and
clears it when the meeting starts.

Built 2026-11-04 because the GCal for Google Calendar app and Chrome were unreliable at
delivering Google Calendar reminders.

## How it works

- `main.swift` reads events through EventKit, so it sees every account in Apple Calendar.
  Google calendars get there via System Settings → Internet Accounts → Google (Calendars on).
- Every 20 s (and instantly on any calendar change) it looks for timed events starting within
  the lead time, skips all-day, cancelled and declined events, posts one notification per
  occurrence, re-posts it with the same identifier each time the minutes-left figure changes
  (a one-shot timer fires exactly on each minute boundary), and removes it at the event's start.
- Notifications go through UserNotifications as "Meeting Alerts". If that permission is off it
  falls back to `osascript display notification` (shows as Script Editor).
- A launchd agent keeps it running and starts it at login.

## Files

| File | Purpose |
|------|---------|
| `main.swift` | the whole app |
| `Info.plist` | bundle metadata incl. the calendar usage description macOS requires |
| `build.sh` | compiles + ad-hoc signs into `~/Applications/Meeting Alerts.app` |
| `install.sh` | copies the launchd plist into `~/Library/LaunchAgents` and (re)starts the agent |
| `com.elityre.meeting-alerts.plist` | the launchd agent definition |

## Runtime locations

- Config: `~/Library/Application Support/MeetingAlerts/config.json`, reloaded live:
  ```json
  { "leadMinutes": 10, "calendars": ["Eli - Palisade"], "attendeesOnly": false }
  ```
  Empty `calendars` means every calendar.
- State (what has been notified): `~/Library/Application Support/MeetingAlerts/state.json`
- Log: `~/Library/Logs/meeting-alerts.log`

## Common tasks

```sh
./build.sh && ./install.sh      # rebuild after editing main.swift and restart the agent
"$HOME/Applications/Meeting Alerts.app/Contents/MacOS/MeetingAlerts" --test
                                # list calendars/events EventKit sees and send a test notification
"$HOME/Applications/Meeting Alerts.app/Contents/MacOS/MeetingAlerts" --countdown-test
                                # post a fake warning and count it 3 → 2 → 1 min over 15 s, then clear it
tail -f ~/Library/Logs/meeting-alerts.log
launchctl bootout gui/$(id -u)/com.elityre.meeting-alerts   # stop it
```

## Settings that matter

- System Settings → Notifications → Meeting Alerts: allow, style **Alerts** (Banners slide away).
- Calendar app → Settings → Accounts → Google → Refresh Calendars: **Every minute**
  (default is 15 min, so a last-minute event could be missed).
- macOS hides declined events from apps, so declined meetings never get a warning.

## Gotchas learned

- Scripts run from launchd cannot read the Calendar database (TCC denies silently); a signed
  app bundle with a usage description is required.
- Re-posting a notification with the same identifier replaces it in Notification Center (verified
  with `--countdown-test`: one entry, title updated). On screen macOS may re-animate the alert on
  each update rather than editing it in place; if the once-a-minute motion is annoying, the
  countdown lives in the `minutesLeft(secs) != e.lastMins` branch of `tick()` in `main.swift`.
- Each `build.sh` re-signs ad hoc, so a test run from a sandboxed shell can report
  `calendar access granted=false`; the launchd-run agent keeps its grant.
