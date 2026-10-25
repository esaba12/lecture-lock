# Manual tests

Things the code can't check by itself, because they mean actually locking the Mac. Build with `./build.sh`, run `LectureLock.app`, and keep the emergency phrase handy: `i am choosing to stop learning`.

Status: partly run for the October 2026 round (PRs #1–#13). Ticked items passed a scripted run on 2026-10-25 (locks started by a schedule, Force Quit done with `kill -9`, results read from the saved settings). The rest need someone at the keyboard. Tick them off here as you go.

## Lock basics
- [ ] Duration slider keeps its value after quitting and reopening. (#1)
- [x] Browser lock: opening another tab snaps back. (#2, #3)
- [ ] Closing the lecture tab reopens it.
- [ ] With a second Chrome window on another display, clicking into it brings the lecture window back.
- [ ] Freeze the browser (e.g. a page stuck in `while(true){}` in another tab) while locked: LectureLock's countdown and exit field keep working. (#3)

## Notifications and window (#4)
- [ ] First lock asks for notification permission.
- [ ] A 6-minute timer shows "5 minutes left" about a minute in.
- [ ] Manual mode shows "you can finish now" when the minimum time is up.
- [ ] Close the window, lock from the menu bar, let it finish: the window comes back with the chime.

## Open at login (#5)
- [ ] Turning it on registers the app (System Settings › General › Login Items). If macOS asks for approval, the hint shows.
- [ ] Log out and back in: LectureLock is in the menu bar.

## Force Quit and restarts (#6)
- [x] Lock, then Force Quit LectureLock (⌥⌘⎋): it comes back within ~10 s, still locked, with the same time left. *(came back in 1 s)*
- [x] Same with a browser lock: it reopens on the lecture tab.
- [x] Finish a lock normally, then Force Quit: it does **not** come back (`pgrep -fl "LectureLock --watchdog"` shows nothing).
- [ ] With Open at login on: lock, restart the Mac, and the lock is restored after login.

## Emergency exit (#7)
- [ ] Pasting the phrase into the exit field does nothing; typing it works.
- [x] Hard mode survives a Force Quit (still on in the saved lock).
- [ ] Hard mode (AFTER 15 MIN): the field is replaced by a countdown for 15 minutes.

## History (#8)
- [x] A finished lock is saved to history.
- [ ] After a finished lock (≥1 min) the stats line appears under the headline; an emergency exit adds "1 EXIT".
- [ ] The menu bar shows "Today: … · N-day streak".

## Hotkey (#9)
- [ ] ⌃⌥L in a browser tab locks in with the saved settings.
- [ ] ⌃⌥L where it can't lock (e.g. video mode with no video) plays the error sound and shows the window with the reason.

## Breaks (#10)
- [ ] 25 + 5 with a 30-min total: work 25 → chime, apps free, menu bar ☕ → session ends at 25 (no trailing break).
- [ ] During a break, BACK TO WORK → re-locks right away and pulls the end time in.
- [ ] Quick timers from the menu bar ignore the break setting.

## Schedules (#11)
- [x] Add a schedule for a minute from now in a browser with a page: at that time the browser opens the page and locks.
- [x] A schedule for an app that doesn't exist doesn't retry until the next day.
- [ ] …and shows the window with the reason.

## Layout (#13)
- [ ] With Advanced open on a 13–14" screen the window fits, the settings scroll, and LOCK IN stays visible.
