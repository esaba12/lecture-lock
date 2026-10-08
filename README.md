# Lecture Lock

A tiny macOS app: click **LOCK IN** and your Mac is locked to the lecture you're watching until the timer runs out.

- Every other app gets hidden the moment it's activated (Cmd-Tab, Dock, Spotlight — all bounce you back).
- In a browser (Chrome, Safari, Arc, Brave, Edge) you're pinned to the lecture **tab**: switching tabs snaps back, closing it reopens it. YouTube locks to the exact video.
- Quit the browser and it relaunches on the lecture. LectureLock itself ignores Cmd-Q while locked.
- **Advanced** (collapsed by default):
  - **Unlock when…**
    - **Timer ends** (default) — 5–180 min slider.
    - **Video ends** — unlocks when the page's video finishes. Skipping ahead snaps back to the furthest point watched; speed-ups are fine; YouTube ads are ignored.
    - **I reach a link** — e.g. `sqlbolt.com/lesson/end`. Only counts if you click your way there (typed URLs have no referrer).
    - **I finish a course** — built-in SQLBolt support: pick a goal lesson; each lesson counts once all its exercises are solved, starting from the lesson you're on.
    - **Page shows text** — e.g. `Accepted`, `Submitted`, `Congratulations`.
    - **I say I'm done** — an *I'm done* button appears after a minimum time.
  - **Stay on** — this page or the whole site (link/course/text modes always use the whole site, so you can move between pages).
  - **Also allow** — let a notes app (Notes, Notion, GoodNotes…) through alongside the lecture.
  - **Menu bar timer** — time left / lessons done shows in the menu bar while locked.
- Video, link, course and text modes read the page with a little JavaScript. One-time setup: Chrome/Brave › View › Developer › *Allow JavaScript from Apple Events* (Safari: Develop › same option).
- Emergency exit: type `i am choosing to stop learning`.

## Build

Requires macOS 14+ and the Xcode command line tools.

```sh
./build.sh
open LectureLock.app
```

The first time you lock a browser tab, macOS asks to let LectureLock control the browser — click **Allow** (or enable it in System Settings › Privacy & Security › Automation).

## Limits

It's friction, not a jail: Force Quit (⌥⌘⎋) can still kill it. On non-YouTube sites the lock matches the page's host + path, so e.g. other Panopto videos are reachable. "Until video ends" can't see videos embedded from another site (e.g. Panopto inside Canvas) — open the video directly or use the timer.

No AI or network calls at runtime: it's plain Swift + AppleScript.
