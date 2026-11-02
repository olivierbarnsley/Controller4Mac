# Controller4Mac 🎮

[![Swift](https://img.shields.io/badge/Swift-5.0+-FA7343?logo=swift&logoColor=white)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-13.0+-000000?logo=apple&logoColor=white)](https://apple.com/macos)
[![Xcode](https://img.shields.io/badge/Xcode-15.0+-1575F9?logo=xcode&logoColor=white)](https://developer.apple.com/xcode/)
[![Framework](https://img.shields.io/badge/Framework-GameController%20%7C%20CoreGraphics-blue)](#architecture-overview)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A high-performance, native macOS menu bar agent that transforms gamepads into high-precision system mice, virtual scroll wheels, and shortcut remap controllers. Built with **SwiftUI**, **Combine**, Apple's **GameController** framework, and low-level **CoreGraphics HID event synthesis**, **Controller4Mac** bridges the gap between couch gaming and macOS desktop navigation with zero-latency profile auto-switching.

---

## ⚡ Highlights

- 🕹️ **Analog Mouse & 2-Axis Scrolling** — 60 FPS sub-pixel cursor movement and continuous scrolling with customizable deadzones and multi-monitor edge clamping.
- 🔄 **Intelligent Profile Switching** — Seamlessly toggles between **Desktop Mode** (cursor & click remapping) and **Blank Mode** (raw pass-through for games and emulators).
- 🧠 **Three-Tier Emulator Detection** — Automatically switches to Gamepad pass-through when Ryujinx, PCSX2, Dusk, ES-DE, Dolphin, or RetroArch take focus.
- 🎯 **Context-Aware Hardware Chords** — System shortcuts for instant app termination (`Cmd+Q`), sleep (`pmset sleepnow`), window focus, and Escape key injection directly from the controller.
- 🚀 **Zero-Touch Console Mode Wake-to-Play** — Auto-triggers macOS Shortcuts on primary controller wake with lock-screen debounce handling.
- 🪶 **Lightweight Menu Bar Daemon** — Runs silently with no Dock icon or Cmd+Tab footprint (`LSUIElement`), featuring a dark glass vibrancy status panel.

---

## 🚀 Key Features

### 1. High-Frequency Analog Cursor & Scroll Engine
* **60 FPS Delta-Time Accumulation**: Drives mouse cursor movement using a high-precision `Timer` scheduled on the main run loop in `.common` mode, ensuring stutter-free movement even while modal dialogues or menus are active.
* **Deadzone & Drift Filtration**: Enforces a 10% hardware deadzone threshold to eliminate stick drift and unwanted cursor drift from worn analog sticks.
* **Sub-Pixel 2-Axis Scrolling**: Translates right thumbstick input into smooth horizontal and vertical `CGEvent` scroll wheel events with fractional remainder accumulation.
* **Multi-Monitor Display Clamping**: Automatically queries the union bounding box across all active screens (`NSScreen.screens`) to ensure the virtual cursor cleanly traverses multi-monitor workspaces without escaping virtual desktop boundaries.

### 2. Zero-Touch Profile Switching (`Desktop` vs. `Blank`)
* **Desktop Profile**: Thumbsticks drive mouse movement and scrolling; face buttons dispatch native left and right mouse click events.
* **Blank Profile (Game Pass-Through)**: Suppresses all synthetic cursor and mouse events, giving emulators and native games exclusive, unhindered access to raw gamepad inputs.
* **Automatic Focus Detection**: Listens to `NSWorkspace.didActivateApplicationNotification` and evaluates active apps across a 3-tier cascade:
  1. **Tier 1 — Exact Bundle ID**: Matches canonical identifiers (`org.ryujinx.Ryujinx`, `org.dolphin-emu.dolphin`, `com.libretro.RetroArch`, etc.).
  2. **Tier 2 — Fuzzy Localized Name**: Inspects window/application names for variants like headless runners or custom forks.
  3. **Tier 3 — Executable Path Fallback**: Inspects `executableURL.lastPathComponent` for command-line binaries and AppImage wrappers (e.g., `ryujinx-bin`).
* **Manual Override**: Press **L3 + R3** simultaneously at any time to toggle profiles on the fly.

### 3. Context-Aware Hardware Chords & Safety Catches
Controller4Mac intercepts multi-button combinations to control macOS without needing a physical keyboard:

| Chord | Context | Action Performed |
|---|---|---|
| **L1 + Menu/Start + D-Pad Down** | **ES-DE** or **Finder** | Puts macOS to sleep immediately (`/usr/bin/pmset sleepnow`) |
| **L1 + Menu/Start + D-Pad Down** | **Ryujinx** (Blank Mode) | Posts in-place Left Click to capture & hide the mouse cursor |
| **L1 + Menu/Start + D-Pad Down** | Standard Applications | Dispatches `Cmd+Q` with a 1-second fallback to force Desktop mode if an unsaved dialog appears |
| **L1 + Menu/Start + D-Pad Up** | Any Application | Injects genuine hardware Escape key (`.hidSystemState`) and forces Desktop mode for settings navigation |
| **L1 + Menu/Start + D-Pad Left / Right** | Any Application | Switches macOS Spaces (`Ctrl+←` / `Ctrl+→`) |
| **L3 + R3 (Simultaneous Click)** | Any Application | Manually toggles active profile between `.desktop` and `.blank` |

### 4. Zero-Touch Console Mode Wake-to-Play
* Detects the first controller connection (`GCController.controllers().count == 1`) to trigger a configured macOS Shortcut (`/usr/bin/shortcuts run "Console Mode"`).
* **2.5-Second Unlock Debounce**: Delays execution when waking from system sleep to allow Apple Watch or Touch ID proximity unlock sequences to clear the lock screen before running foreground UI scripts.
* **Mid-Session Safeguard**: Automatically suppresses the shortcut if waking into an active game session in `.blank` mode, while preserving execution when waking into Finder, ES-DE, or `.desktop` debug mode.

### 5. Multi-Controller Arbitration & Promotion Cascade
* **Player 1 Designation**: Locks cursor simulation and system chord evaluation to the primary controller to prevent input collisions during local multiplayer sessions.
* **Secondary Controller Isolation**: Additional controllers connected via Bluetooth or USB are recognized and logged without interfering with system navigation.
* **Promotion Cascade**: If Player 1 disconnects, the next connected gamepad is promoted to Player 1 instantly.

---

## 🏛️ Architecture Overview

```
                      ┌─────────────────────────────────────────┐
                      │   Hardware Gamepads (Bluetooth / USB)   │
                      │   Xbox • Switch Pro • DualSense • MFi   │
                      └────────────────────┬────────────────────┘
                                           │
                                           ▼
                      ┌─────────────────────────────────────────┐
                      │        GameController Framework         │
                      │  GCController (Background HID Polling)  │
                      └────────────────────┬────────────────────┘
                                           │
                                           ▼
                      ┌─────────────────────────────────────────┐
                      │            ControllerManager            │
                      │  • Player 1 Lock & Promotion Cascade    │
                      │  • Context-Aware Hardware Chords        │
                      │  • Shortcut Trigger & Sleep Dispatcher  │
                      └─────────────┬───────────────────────────┘
                                    │
                  ┌─────────────────┴─────────────────┐
                  ▼                                   ▼
        [Desktop Profile Active]            [Blank Profile Active]
                  │                                   │
                  ▼                                   ▼
      ┌─────────────────────────┐            ┌──────────────────┐
      │  MouseSimulationManager │            │ Native Gamepad   │
      │  • 60 FPS Display Tick  │            │ Pass-Through     │
      │  • Deadzone Filtration  │            │ (Emulators /     │
      │  • Multi-Screen Clamp   │            │  Fullscreen)     │
      └───────────┬─────────────┘            └──────────────────┘
                  │
                  ▼
      ┌─────────────────────────┐
      │   CoreGraphics (CGEvent)│
      │   • mouseMoved          │
      │   • leftMouseDown/Up    │
      │   • rightMouseDown/Up   │
      │   • scrollWheelEvent2   │
      │   • keyboardEventSource │
      └───────────┬─────────────┘
                  │ (CGEventTapLocation.cghidEventTap)
                  ▼
      ┌─────────────────────────┐
      │  macOS Window Server    │
      └─────────────────────────┘
```

### Subsystem Breakdown

* **`ControllerManager`**: Central coordinator for gamepad discovery, background input events (`GCController.shouldMonitorBackgroundEvents = true`), hardware chord evaluation, and Player 1 lifecycle arbitration.
* **`MouseSimulationManager`**: High-frequency cursor positioning and scroll wheel synthesis. Uses an `NSLock` to safely bridge raw analog stick floats from the background GameController callback thread into the 60 FPS display loop.
* **`ProfileManager`**: Observes application activation via `NSWorkspace` notifications and manages profile state (`.desktop` vs. `.blank`) using a 3-tier target lookup hierarchy.
* **`AccessibilityManager`**: Interrogates `AXIsProcessTrustedWithOptions` to verify macOS Accessibility permissions at launch and maintains a lightweight 1.0s background poll to detect permission toggles without restarting the app.
* **`Controller4MacApp` & `ContentView`**: SwiftUI menu bar interface (`MenuBarExtra`) using `.window` presentation style and AppKit `NSVisualEffectView` backing for dynamic macOS blur and status telemetry.

---

## 🔒 Security, Permissions & Sandboxing

### Why Accessibility Permission is Required
Synthesizing system-wide mouse movements, mouse clicks, and keystrokes on macOS requires **Accessibility (AX)** authorization:
* `CGEvent.post(tap: .cghidEventTap)` injects events directly into the macOS HID event stream.
* Without Accessibility trust, macOS silently drops synthetic HID events without raising an error. Controller4Mac monitors this state and provides a one-click deep link to **System Settings → Privacy & Security → Accessibility**.

### Why App Sandbox is Disabled
In [Controller4Mac.entitlements](Controller4Mac/Controller4Mac.entitlements), `com.apple.security.app-sandbox` is set to `false`. macOS App Sandbox policies prohibit inter-process event injection; an unsandboxed runtime is mandatory for any system-level controller-to-mouse mapping utility on macOS.

---

## 🛠️ Build & Run Instructions

### Prerequisites
* **macOS 13.0 (Ventura)** or later
* **Xcode 15.0+**
* An Apple Silicon or Intel Mac
* A compatible Bluetooth or USB controller (Xbox One/Series, Nintendo Switch Pro, PlayStation DualSense/DualShock 4, or MFi)

### 1. Clone the Repository
```bash
git clone https://github.com/SuperRice6/Controller4Mac.git
cd Controller4Mac
```

### 2. Open in Xcode
```bash
open Controller4Mac.xcodeproj
```

### 3. Configure Signing & Capabilities
1. In Xcode's Project Navigator, select the **Controller4Mac** target.
2. Navigate to **Signing & Capabilities**.
3. Select your personal Apple Developer Team under **Team**.
4. Ensure **Hardened Runtime** is enabled and **App Sandbox** is disabled (matching `Controller4Mac.entitlements`).

### 4. Build and Run
1. Press `Cmd + R` or click the **Run** button in Xcode.
2. The Controller4Mac icon (`gamecontroller.fill`) will appear in your macOS menu bar.
3. On first launch, grant **Accessibility** access when prompted, or click **Open Settings** in the menu bar popover to enable it under **Privacy & Security → Accessibility**.
4. Connect your controller via Bluetooth or USB and enjoy!

---

## 🎮 Supported Hardware

Tested and verified on macOS 14 & 15:
- **Microsoft Xbox**: Xbox Wireless Controller (Model 1708+), Xbox Elite Series 2
- **Nintendo**: Nintendo Switch Pro Controller, Joy-Cons
- **Sony PlayStation**: DualSense (PS5), DualShock 4 (PS4)
- **Third-Party / MFi**: 8BitDo (macOS / Switch mode), SteelSeries Nimbus, Backbone One

---

## 📄 License

This project is licensed under the [MIT License](LICENSE) — see the LICENSE file for details.

---

## 👤 Author

**Olivier Barnsley**
* GitHub: [@SuperRice6](https://github.com/SuperRice6)
