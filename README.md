# Lecture Lock

A tiny macOS app: click **LOCK IN** and your Mac is locked to the lecture you're watching until the timer runs out.

- Every other app gets hidden the moment it's activated (Cmd-Tab, Dock, Spotlight — all bounce you back).
- In a browser (Chrome, Safari, Arc, Brave, Edge) you're pinned to the lecture **tab**: switching tabs snaps back, closing it reopens it. YouTube locks to the exact video.
- Quit the browser and it relaunches on the lecture. LectureLock itself ignores Cmd-Q while locked.
- Emergency exit: type `i am choosing to stop learning`.

## Build

Requires macOS 14+ and the Xcode command line tools.

```sh
./build.sh
open LectureLock.app
```

The first time you lock a browser tab, macOS asks to let LectureLock control the browser — click **Allow** (or enable it in System Settings › Privacy & Security › Automation).

## Limits

It's friction, not a jail: Force Quit (⌥⌘⎋) can still kill it. On non-YouTube sites the lock matches the page's host + path, so e.g. other Panopto videos are reachable.
