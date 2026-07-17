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
- When input is idle, the webcam checks whether you are still watching
  (on-device Vision face detection; frames are analyzed and discarded, never
  stored or sent anywhere). Reading a static page without touching the
  computer still counts as screen time.
- Camera use follows the power source. Plugged in, it runs continuously and
  tracks more actively: head pose including pitch, eye openness (closing your
  eyes for 20 seconds counts as a break), and coarse gaze from pupil position,
  at 2 frames per second. On battery, a lighter face/head-pose check runs only
  while input is idle, at 1 frame per second.
- Looking away (no input and no face) for **20 seconds** counts as an eye
  break and resets the clock.
- If a due break is ignored, it reminds you again after 5 minutes.

## Multiple displays

- With one display, a face is counted as watching only when it roughly faces
  the screen (head yaw within about 40 degrees of the camera).
- With two or more displays, any visible face counts as watching, because
  looking at an external main monitor turns your head away from the built-in
  camera. This switches automatically when displays connect or disconnect.
- If you work in clamshell mode (lid closed), the built-in camera sees
  nothing. Attach an external webcam to your main monitor and select it under
  **Camera Device** in the menu. Without one, keyboard/mouse input still
  counts as watching, but reading without input cannot be detected.

## Menu

- **Next break in M:SS** — current status.
- **Reset Timer** — start the current interval over.
- **Pause / Resume** — stop and resume tracking.
- **Break Interval** — choose 15, 20, 25, 30, 45, or 60 minutes.
- **Use Camera** — toggle webcam presence detection (off = input only).
- **Camera Device** — pick which camera to use (e.g. an external webcam on
  your main monitor).
- **How EyeHealth Works…** — opens an explainer panel describing detection,
  camera policy, multi-display behavior, and privacy.
- **Open at Login** — launch EyeHealth automatically when you log in.
- **Quit EyeHealth**.

## Build

Requires the Xcode Command Line Tools (Swift 5.9+). No full Xcode needed.

```sh
./build.sh
open dist/EyeHealth.app
```

`build.sh` compiles with Swift Package Manager, assembles `dist/EyeHealth.app`
with the bundled bloodshot-eye icon (`Resources/EyeHealth.icns`), and ad-hoc
code-signs it. The icon is drawn programmatically; regenerate it with
`swift scripts/make_icon.swift icon_1024.png` and rebuild the icns via
`iconutil` if you change the artwork.

On first launch macOS asks for notification permission. Click **Allow** so the
break reminders can appear.

To install it permanently, drag `dist/EyeHealth.app` into `/Applications` and
enable **Open at Login** from the menu.

## Requirements

- macOS 13 or later.
