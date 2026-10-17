# Remote Control

A small macOS menu bar app that turns the Siri Remote (2nd generation and later, the aluminium one with the clickpad) into a Mac remote and trackpad, along the lines of Remote Buddy.

## What it does

**Remote mode** (default mapping)

| Button | Action |
| --- | --- |
| Clickpad up / down | Volume up / down |
| Clickpad left / right | Previous / next track |
| Clickpad centre | Play / pause |
| Back | ← Left arrow key |
| TV / Home | → Right arrow key |
| Play/Pause | Play / pause |
| Volume + / − | Volume up / down |
| Mute | Mute |
| Power | Sleep display |
| Siri (side button) | Switch between remote and trackpad mode |

**Trackpad mode**: slide on the clickpad to move the pointer. Press the clickpad to left-click (press and slide to drag). Back is a right-click. To scroll, rest your finger still for a moment, then draw circles: clockwise scrolls down, anticlockwise scrolls up. The other buttons keep their remote-mode actions.

You can remap every button in both modes from **Settings → Buttons**.

Also:

- **Right-click the menu bar icon** (or ⌃-click) to turn the app on or off. A left-click opens the menu.
- **Battery**: shows the remote's charge, sends a notification when it falls to your chosen level (default 20%), and keeps a history. Pick Past Week or Past Month to see a level chart (hover for exact readings), your average daily use with an estimate of how long the charge will last, and one section per day with % used, start and end level, charging, a 24-hour chart and the individual readings. A reading is saved whenever the level changes, and every 30 minutes otherwise. History lives in `~/Library/Application Support/com.runaroundhome.RemoteControl/battery-history.json` and is kept for 35 days.
- **Pairing**: lists remotes this Mac has seen, unpairs them, and walks you through pairing a new one.
- **Diagnostics**: shows why a button might not be working. It covers permissions, apps holding the remote (such as Remote Buddy), Secure Input, other apps filtering events, and whether the remote is asleep. It has a live picture of the remote that lights up as you press, plus an event log of each press and what it did.

## Build and install

You need Xcode 16 or later (built and tested with Xcode 27.1 on macOS 27).

```bash
scripts/build-app.sh --install
```

That builds `build/Remote Control.app`, copies it to `/Applications`, and launches it. Use `--run` to launch from `./build` without installing, or pass no flag to build only.

### Signing (do this once)

macOS ties the Accessibility and Input Monitoring permissions to the app's code signature. Without a real signing identity the build is ad-hoc signed, and you'll have to grant both permissions again after every rebuild.

Fix: open Xcode → Settings → Accounts and add your Apple ID. A free account is fine. Xcode creates an "Apple Development" certificate, and `build-app.sh` picks it up automatically. To use a specific identity, set `CODESIGN_IDENTITY="…"`.

### Permissions

On first launch the app opens Diagnostics and asks for:

- **Accessibility**: to send keys, clicks, pointer movement, scrolling and media keys.
- **Input Monitoring**: to read the remote's buttons.
- **Notifications**: for low-battery alerts.
- **Bluetooth**: only when you use Find Remote or Unpair.

### Remote Buddy

Quit Remote Buddy while using this app; both try to grab the remote. Diagnostics shows when it's running and has a Quit button. The app retries opening the remote every few seconds, so it takes over as soon as Remote Buddy lets go.

## How it works

- **Buttons**: the remote shows up as a Bluetooth LE HID device (vendor 0x004C, product 0x0314). Every button is a 1-bit field in one Consumer Control report. The app opens that interface with `IOHIDManager`, with exclusive access by default, so macOS's own handling doesn't also fire. That handling is the Music app opening on Play and double volume steps. The usage table is in `Sources/RemoteCore/SiriRemoteHID.swift`.
- **Touch**: macOS turns the remote's digitizer into an `AppleMultitouchDevice`. The app reads finger positions through the private MultitouchSupport framework, loaded at runtime with `dlopen`. `TouchGestureRecognizer` turns frames into pointer moves and hold-then-circle scrolling. Scrolling follows how much the finger's direction of travel turns, so any size of circle anywhere on the pad works.
- **Output**: `CGEvent` for keys, mouse and scroll, and `NSEvent` system-defined events for media keys (the same events as the keyboard's F7–F12 keys).
- **Battery**: read from the accessory power sources macOS publishes, the same data as `pmset -g accps`.

## Project layout

```
Sources/RemoteCore      pure logic: buttons, actions, mappings, HID usage table, gesture recognizer (unit-tested)
Sources/CShims          C shim for MultitouchSupport (dlopen) and libproc
Sources/RemoteControl   the app: HID/touch input, event output, services, SwiftUI settings window
Tests/RemoteCoreTests   swift test
scripts/build-app.sh    builds, bundles, signs (and optionally installs) the .app
```

Run the tests with `swift test`. To render each settings tab to PNGs without starting input, run `"build/Remote Control.app/Contents/MacOS/RemoteControl" --snapshot <dir>`.
