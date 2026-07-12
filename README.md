# EyeHealth

A tiny macOS menu bar app that tracks continuous screen time and reminds you to
rest your eyes, following the **20-20-20 rule**: every 20 minutes, look about
20 feet (6 m) away for 20 seconds.

## How it works

- Lives in the menu bar as an eye icon with a live countdown. No dock icon.
- Measures how long you've continuously watched the screen using the system's
  input-idle timer. No camera and no accessibility permission are required.
- When the interval is up it posts a notification with a sound telling you to
  look away.
- It notices when you actually rest:
  - **20 seconds** of no keyboard/mouse input clears a due break.
  - **3 minutes** of no input means you stepped away, so the timer resets and
    starts fresh when you come back.
- If a due break is ignored, it reminds you again after 5 minutes.

## Menu

- **Next break in M:SS** — current status.
- **Reset Timer** — start the current interval over.
- **Pause / Resume** — stop and resume tracking.
- **Break Interval** — choose 15, 20, 25, 30, 45, or 60 minutes.
- **Open at Login** — launch EyeHealth automatically when you log in.
- **Quit EyeHealth**.

## Build

Requires the Xcode Command Line Tools (Swift 5.9+). No full Xcode needed.

```sh
./build.sh
open dist/EyeHealth.app
```

`build.sh` compiles with Swift Package Manager, assembles `dist/EyeHealth.app`,
and ad-hoc code-signs it.

On first launch macOS asks for notification permission. Click **Allow** so the
break reminders can appear.

To install it permanently, drag `dist/EyeHealth.app` into `/Applications` and
enable **Open at Login** from the menu.

## Requirements

- macOS 13 or later.
