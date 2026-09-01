# NightOwl

A featherweight **macOS menu bar utility** that keeps your Mac awake with a single `IOPMAssertion` — perfect for long downloads, renders, VM guests, presentations, and remote sessions. Flip the switch and the sleepy owl in your menu bar opens its big round eyes: your Mac won't doze off until you tell it to.

[![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)](https://www.swift.org)
[![Platform](https://img.shields.io/badge/macOS-14%2B-1f6feb?logo=apple)](https://www.apple.com/macos)
[![Architecture](https://img.shields.io/badge/Apple%20Silicon-arm64-purple)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-dwyi84d-FFDD00?logo=buymeacoffee&logoColor=black&style=flat-square)](https://buymeacoffee.com/dwyi84d)

---

<img width="412" height="720" alt="nightowl" src="https://github.com/user-attachments/assets/2eb8ee47-cd0a-4004-a2ca-6137bfb6350b" />

## Features

- **One-Switch Keep Awake** — a single toggle holds a native `IOPMAssertion`; no daemons, no login items, no background overhead. The menu bar owl sleeps when your Mac may sleep and wakes up when it can't.
- **Two Protection Modes**
  - *System Only* — the display may sleep and lock; the system itself stays awake.
  - *Display + System* — neither the display nor the system may idle-sleep.
- **Auto-Stop Timer** — run forever (`∞`), pick a preset (**15m / 30m / 1h / 2h**), or dial in any duration with **±10m / ±1h** steppers (10 minutes up to 24 hours). A live countdown in the panel shows exactly how long the owl stays on watch, and a macOS notification tells you when it lets go.
- **Smart SafeGuard** — NightOwl never fights a dying battery or an overheating machine:
  - releases automatically the moment the **power adapter is unplugged**,
  - releases automatically when the **battery drops to 20%** or below,
  - **Thermal Guard** (on by default) releases the session the instant macOS reports `.serious`/`.critical` thermal state,
  - safeguards adapt to your hardware — battery and closed-lid options appear only on laptops (detected dynamically, never by model name).
- **Closed-Lid Keep-Awake (experimental)** — on Apple Silicon, a `PreventSystemSleep` assertion can hold a lid-closed MacBook in powered DarkWake (display off, system running) instead of full sleep, so background builds and LLM runs keep going with the lid shut. Requires AC power: unplug the cable, the close-lid session releases with it. NightOwl never blocks the sleep itself — lid close transitions are honored the moment the session ends.
- **Code-Drawn Owl Icon** — the menu bar glyph is pure SwiftUI `Shape`/`Path` vector art (head, ear tufts, beak, wide-open or sleepy closed eyes). No image assets, and it renders as a template image so it follows the menu bar tint in light and dark mode.
- **One-Click Auto-Update** — "Check for Updates" queries the GitHub Releases API, and when a newer version is found it downloads, replaces the running app in place, and relaunches — all from one click.
- **Scroll-Free 320pt Panel** — every control fits on one screen: toggle, mode segment, timer chips, safeguards, live status, and footer actions.
- **Honest Defaults** — preferences (mode, timer, safeguards) are remembered, but NightOwl always starts **off** after a relaunch, so it never keeps a Mac awake behind your back.
- **Reset** — restore every setting to its default with one click.
- **Tiny & Private** — a single self-contained binary. No analytics, no tracking.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (arm64)
- Xcode Command Line Tools (for the Swift toolchain)

## Installation

Clone the repository and build:

```bash
git clone https://github.com/dwyi84/NightOwl.git
cd NightOwl
./build.sh
```

`build.sh` compiles the app with Swift Package Manager, assembles `NightOwl.app` (with an `LSUIElement` bundle so it lives quietly in the menu bar), signs it with a stable local identity, and launches it.

## Usage

| Action | Result |
| --- | --- |
| Click the owl in the menu bar | Open the control panel |
| Toggle **Keep Awake** | Start / stop the power assertion |
| Right-click the owl | Quick toggle / quit |
| Pick **System Only** or **Display + System** | Choose what stays awake |
| Pick **∞, 15m, 30m, 1h, 2h** or step **−1h / −10m / +10m / +1h** | Set the auto-stop time |
| Toggle safeguards | Release automatically on AC unplug / low battery |

### Smart SafeGuard

While the assertion is active, NightOwl watches the power supply through IOKit:

- **AC unplug** — the moment the adapter is disconnected, the assertion is released and a notification fires. Great for desktop-docked setups: lift the MacBook off the desk and it goes back to normal battery behavior.
- **Battery limit (20%)** — if the battery level reaches 20% while running on battery power, the assertion is released automatically to preserve runtime.

### Verifying the assertion

The power assertion is fully inspectable with the system tool:

```bash
pmset -g assertions
```

While active you will see `PreventUserIdleSystemSleep` (System Only) or `PreventUserIdleDisplaySleep` (Display + System) attributed to `NightOwl`.

## Settings

- **Keep Awake** — master on/off switch; the owl icon reflects the state.
- **Mode** — *System Only* (display may sleep/lock) or *Display + System*.
- **Auto-Stop** — `∞` or a 15m / 30m / 1h / 2h preset, or dial any custom duration with the −1h / −10m / +10m / +1h steppers (10 minutes to 24 hours), with a live countdown in Status.
- **Smart SafeGuard** — independent toggles for AC-unplug release, the 20% battery floor, and Thermal Guard, plus the current power source and battery level.
- **Keep running with lid closed** — laptop-only experimental option (AC required); the owl keeps the system powered in DarkWake while the lid is shut and releases everything the moment you unplug, overheat, or stop the session.
- **Status** — always-on row showing the remaining time (or `∞`) plus the current state and the reason for the last automatic release.
- **Check for Updates** — header button that downloads and installs newer GitHub releases in one click.
- **Reset** — restore all settings to their defaults.
- **Quit** — exit NightOwl (the assertion is released first).

Mode, timer, and safeguard choices are saved automatically; NightOwl always launches inactive.

## Development

Pure Swift Package Manager — no Xcode project required:

```bash
swift build -c release   # compile
./build.sh               # build, bundle, sign, launch
```

```
Sources/NightOwl/
├── NightOwlApp.swift       # @main, status item, popover, right-click menu
├── SleepManager.swift      # IOPMAssertion engine, timer, safeguards, persistence
├── MainPopoverView.swift   # 320pt single-screen SwiftUI panel
├── OwlIconView.swift       # vector owl face + menu bar template image
└── UpdaterViewModel.swift  # GitHub Releases auto-update flow
```

## Privacy

NightOwl talks to two things only: the macOS power-management system (local IOKit calls) and GitHub's Releases API (only when you press "Check for Updates"). It collects nothing, uploads nothing, and stores its preferences in `UserDefaults` on your Mac.

## License

Released under the [MIT License](LICENSE).

## Support

If NightOwl keeps your Mac (and your workflow) awake, consider buying me a coffee — it keeps the owl vigilant. ☕

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-dwyi84d-FFDD00?logo=buymeacoffee&logoColor=black&style=for-the-badge)](https://buymeacoffee.com/dwyi84d)

<p align="center">Crafted by MelissaSoft · Made with ❤️ on Apple Silicon.</p>
<p align="center">Copyright © 2026 Dawoon Yi / MelissaSoft</p>
