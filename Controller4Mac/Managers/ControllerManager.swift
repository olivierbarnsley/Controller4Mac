// ControllerManager.swift
// Controller4Mac
//
// Phase 5: Right click, refined kill-switch chord, space-switching chords.
//
// Framework notes:
//   GCController abstracts Xbox and Switch Pro controllers under
//   GCExtendedGamepad on macOS 13+. Button mapping is by physical POSITION:
//     Xbox:        A=bottom, B=right, X=left, Y=top
//     Switch Pro:  A=right,  B=bottom, X=top,  Y=left
//
// Input gating:
//   Mouse/click events → gated by .desktop profile.
//   All chord shortcuts → always active (both profiles).
//
// Chord table (Phase 5):
//   L1 + Menu + D-Pad Down   → Cmd+Q    (quit foreground app)
//   L1 + Menu + D-Pad Left   → Ctrl+←   (switch Space left)
//   L1 + Menu + D-Pad Right  → Ctrl+→   (switch Space right)
//
//   D-Pad chords are evaluated on each D-Pad press while both L1 and Menu
//   are already held, so the exact press order of L1/Menu doesn't matter.

import Foundation
import GameController
import CoreGraphics  // CGEvent for Cmd+Q chord
import Combine

final class ControllerManager: ObservableObject {

    // MARK: - Published State

    /// `true` after a compatible controller connects via USB or Bluetooth.
    @Published var isConnected: Bool = false

    /// Human-readable name reported by the GameController framework.
    /// Examples: "Xbox Wireless Controller", "Pro Controller"
    @Published var controllerName: String? = nil

    // MARK: - Dependencies

    /// Injected at init time. ControllerManager reads `currentProfile` to
    /// decide whether to forward inputs to MouseSimulationManager.
    /// Unowned because ProfileManager is owned by Controller4MacApp and
    /// is guaranteed to outlive ControllerManager.
    private unowned let profileManager: ProfileManager

    // MARK: - Private

    /// The first controller to connect becomes the designated "Player 1".
    /// All input registration and mouse simulation are bound to this instance.
    /// Secondary controllers (multiplayer) are detected and logged, but their
    /// inputs are intentionally ignored to prevent state-collision bugs.
    private var primaryController: GCController?

    /// Owned instance of the mouse/click simulation engine.
    private let mouseSimulation = MouseSimulationManager()

    // ── Chord modifier state ────────────────────────────────────────────────
    // All bools are read/written exclusively on the GCController callback
    // queue (a single serial queue), so no lock is needed.

    /// L1 / Left Shoulder is currently held.
    private var isL1Held:   Bool = false

    /// Start / Menu button is currently held.
    private var isMenuHeld: Bool = false

    /// D-Pad directional states (used for four-way chord evaluation).
    private var isDpadDownHeld:  Bool = false
    private var isDpadLeftHeld:  Bool = false
    private var isDpadRightHeld: Bool = false
    private var isDpadUpHeld:    Bool = false

    /// Left thumbstick click (L3) held state.
    private var isL3Held: Bool = false

    /// Right thumbstick click (R3) held state.
    private var isR3Held: Bool = false

    // MARK: - Initializer

    init(profileManager: ProfileManager) {
        self.profileManager = profileManager
        GCController.shouldMonitorBackgroundEvents = true

        subscribeToConnectionNotifications()

        // Handle controllers that are already connected when the app launches
        // (e.g., a controller paired before the app started).
        if let existing = GCController.controllers().first {
            handleConnect(existing)
        }
    }

    // MARK: - Connection Notifications

    private func subscribeToConnectionNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConnectNotification(_:)),
            name: .GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDisconnectNotification(_:)),
            name: .GCControllerDidDisconnect,
            object: nil
        )

        // ── App-Activation Observer → Auto Profile Switching ─────────────────
        // Automatically switches to .blank when a fullscreen emulator or game
        // gains focus, and back to .desktop when ES-DE (the frontend) is
        // activated. This gives zero-touch profile management without requiring
        // the user to manually toggle L3+R3 every time they launch a game.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    /// The set of app name substrings that should trigger auto-switch to .blank.
    /// Matching is case-insensitive. Add new emulators/games here as needed.
    private let blankProfileApps: [String] = ["Ryujinx", "PCSX2", "Dusk", "ES-DE"]

    @objc private func handleAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
        let name = app.localizedName ?? ""

        if blankProfileApps.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
            guard profileManager.currentProfile != .blank else { return }
            profileManager.setProfile(.blank)
            print("[ControllerManager] 🎮 '\(name)' activated → auto-switched to .blank profile.")
        }
    }

    @objc private func handleConnectNotification(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        handleConnect(controller)
    }

    @objc private func handleDisconnectNotification(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        handleDisconnect(controller)
    }

    // MARK: - Connect / Disconnect Handlers

    private func handleConnect(_ controller: GCController) {
        let name = controller.vendorName ?? "Unknown Controller"

        // Primary controller lock: once Player 1 is assigned, log and ignore
        // any subsequent connections (multiplayer controllers).
        if let primary = primaryController {
            let primaryName = primary.vendorName ?? "Unknown"
            print("[ControllerManager] 🔒 Secondary controller ignored: \(name) (Player 1 is \(primaryName)).")
            return
        }

        // ── Auto-Launch Console Mode (Player 1 only) ────────────────────────
        // Only the very first controller connection (count == 1) triggers the
        // shortcut. Subsequent connections (multiplayer co-op) are silently
        // skipped so the shortcut doesn't re-fire mid-session.
        if GCController.controllers().count == 1 {
            print("[ControllerManager] 🎮 Primary controller connected. Waiting 2.5s for unlock sequence...")

            // Give the OS and proximity unlocker time to clear the lock screen
            // before firing the shortcut, preventing a wake-from-sleep race condition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""

                // Skip the shortcut only if we are actively inside a game/emulator.
                // Waking into ES-DE or the macOS desktop (Finder) should both
                // trigger Console Mode; waking mid-game (e.g. Ryujinx resumed)
                // should not interrupt the session.
                let activeGameApps: [String] = ["Ryujinx", "PCSX2", "Dusk"]
                let isInActiveGame = activeGameApps.contains(where: { appName.localizedCaseInsensitiveContains($0) })

                // Skip only when genuinely mid-session: a game is frontmost AND
                // the profile is .blank. If profile is .desktop (e.g. debugging),
                // always run the shortcut regardless of the frontmost app.
                if isInActiveGame && self.profileManager.currentProfile == .blank {
                    print("[ControllerManager] 🎮 Woke into active game '\(appName)' (Gamepad Mode). Skipping Console Mode shortcut.")
                    return
                }

                print("[ControllerManager] 🚀 Launching Console Mode Shortcut now.")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                process.arguments = ["run", "Console Mode"] // Must match the Shortcut name exactly
                try? process.run()
            }
        } else {
            print("[ControllerManager] 🎮 Additional controller connected. Skipping auto-launch.")
        }

        assignPrimaryController(controller)
    }

    private func handleDisconnect(_ controller: GCController) {
        let name = controller.vendorName ?? "Unknown Controller"
        print("[ControllerManager] Disconnected: \(name)")

        // Clear per-element handlers to break retain cycles.
        controller.extendedGamepad?.valueChangedHandler = nil

        // Only act if the departing controller IS Player 1.
        guard controller === primaryController else {
            print("[ControllerManager] (Secondary controller disconnected — no state change.)")
            return
        }

        primaryController = nil

        // Reset all modifier-key booleans to prevent ghost inputs on reconnect.
        isL1Held        = false
        isMenuHeld      = false
        isDpadDownHeld  = false
        isDpadLeftHeld  = false
        isDpadRightHeld = false
        isDpadUpHeld    = false
        isL3Held        = false
        isR3Held        = false

        // ── Promotion Cascade ────────────────────────────────────────────────
        // If another controller is already connected, promote it to Player 1
        // immediately rather than waiting for a new GCControllerDidConnect.
        // We skip the departing controller itself (identity check) since GCKit
        // may not have removed it from the array yet at the time this fires.
        if let nextController = GCController.controllers().first(where: { $0 !== controller }) {
            let nextName = nextController.vendorName ?? "Unknown Controller"
            print("[ControllerManager] 🔁 Promotion cascade → '\(nextName)' promoted to Player 1.")
            assignPrimaryController(nextController)
        } else {
            // No controllers remaining — update UI to show disconnected state.
            DispatchQueue.main.async {
                self.isConnected    = false
                self.controllerName = nil
            }
        }
    }

    // MARK: - Primary Controller Assignment

    /// Designates `controller` as Player 1, wires LED/index, updates the UI,
    /// and registers all input handlers.
    ///
    /// All paths that make a controller Player 1 — whether a fresh connection
    /// or a promotion cascade — route through here to guarantee consistent
    /// setup with no duplicated logic.
    private func assignPrimaryController(_ controller: GCController) {
        let name = controller.vendorName ?? "Unknown Controller"

        primaryController          = controller
        controller.playerIndex     = .index1
        print("[ControllerManager] 🎮 Player 1 assigned: \(name)")

        DispatchQueue.main.async {
            self.isConnected    = true
            self.controllerName = name
        }

        guard controller.extendedGamepad != nil else {
            print("[ControllerManager] ⚠️  Controller does not expose extendedGamepad. Input polling skipped.")
            return
        }

        registerInputHandlers(for: controller)
    }

    // MARK: - Input Handler Registration

    /// Registers value-changed callbacks for all inputs wired in Phase 3.
    ///
    /// Thread safety:
    ///   GCController handlers fire on a private GCD queue. All paths here
    ///   are either thread-safe (MouseSimulationManager, isL1Held) or
    ///   explicitly dispatched to the main queue for @Published mutations.
    ///
    /// Profile gating:
    ///   Mouse-simulation calls are guarded by `profileManager.currentProfile`.
    ///   Reading a @Published value off the main thread is safe for a Bool
    ///   (atomic load), but we snapshot it at the top of each closure to
    ///   avoid multiple reads with different values mid-handler.
    ///
    /// - Parameter controller: A controller guaranteed to have an extendedGamepad.
    private func registerInputHandlers(for controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }

        // ── Left Thumbstick → Mouse Movement (gated by profile) ──────────────
        // X axis: -1.0 = full left,  +1.0 = full right
        // Y axis: -1.0 = full down,  +1.0 = full up
        // Deadzone is enforced inside MouseSimulationManager.
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            guard let self else { return }
            guard self.profileManager.currentProfile == .desktop else {
                // Blank profile: zero out the stick so the cursor stops if
                // the app switches while the stick is mid-deflection.
                self.mouseSimulation.updateStick(x: 0, y: 0)
                return
            }
            self.mouseSimulation.updateStick(x: xValue, y: yValue)
        }

        // ── Right Thumbstick → Scroll Wheel (gated by profile) ─────────────
        // X axis: horizontal scroll (left/right)
        // Y axis: vertical scroll   (up/down)
        // Deadzone is enforced inside MouseSimulationManager.
        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            guard let self else { return }
            guard self.profileManager.currentProfile == .desktop else {
                self.mouseSimulation.updateScroll(x: 0, y: 0)
                return
            }
            self.mouseSimulation.updateScroll(x: xValue, y: yValue)
        }

        // ── Bottom Face Button → Left Click (gated by profile) ────────────────
        // buttonA = bottom face button  (Xbox: A  |  Switch Pro: B by position)
        gamepad.buttonA.valueChangedHandler = { [weak self] _, _, isPressed in
            guard let self else { return }
            guard self.profileManager.currentProfile == .desktop else { return }
            self.mouseSimulation.handleBottomButton(isPressed: isPressed)
        }

        // ── Right Face Button → Right Click (gated by profile) ───────────────
        // buttonB = right face button  (Xbox: B  |  Switch Pro: A by position)
        // Uses rightMouseDown / rightMouseUp so the system presents context
        // menus correctly in all applications.
        gamepad.buttonB.valueChangedHandler = { [weak self] _, _, isPressed in
            guard let self else { return }
            guard self.profileManager.currentProfile == .desktop else { return }
            self.mouseSimulation.handleRightButton(isPressed: isPressed)
        }

        // ── Left Shoulder (L1) → Chord Modifier (always active) ───────────────
        gamepad.leftShoulder.valueChangedHandler = { [weak self] _, _, isPressed in
            guard let self else { return }
            self.isL1Held = isPressed
            print("[Input] L1  →  \(isPressed ? "held ▼" : "released ▲")")
        }

        // ── Start / Menu Button → Chord Modifier (always active) ──────────────
        // Held state tracked here; chord evaluation happens in the D-Pad handler.
        gamepad.buttonMenu.valueChangedHandler = { [weak self] _, _, isPressed in
            guard let self else { return }
            self.isMenuHeld = isPressed
            print("[Input] Menu  →  \(isPressed ? "held ▼" : "released ▲")")
        }

        // ── D-Pad → Space & Kill-Switch Chords (always active) ────────────────
        //
        // Chord table:
        //   L1 + Menu + D-Pad Down   → Cmd+Q         (quit foreground app)
        //   L1 + Menu + D-Pad Left   → Ctrl+←        (switch Space left)
        //   L1 + Menu + D-Pad Right  → Ctrl+→        (switch Space right)
        //
        // We register individual direction handlers rather than the aggregate
        // dpad.valueChangedHandler so each direction fires independently and
        // we can track their held states precisely.
        //
        // Note: GCControllerDirectionPad provides xAxis/yAxis floats, but the
        // four directional button inputs (.up/.down/.left/.right) give us clean
        // digital isPressed states without threshold math.
        gamepad.dpad.down.valueChangedHandler = { [weak self] _, _, isPressed in
            guard let self else { return }
            self.isDpadDownHeld = isPressed
            guard isPressed, self.isL1Held, self.isMenuHeld else { return }

            // ── Ryujinx Context-Aware Safety Catch ──────────────────────────
            // When Ryujinx is the foreground app the chord behaves differently
            // depending on the active profile, solving cursor-capture issues
            // without risking a renderer deadlock from an unexpected Cmd+Q.
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            if appName.contains("Ryujinx") {
                switch self.profileManager.currentProfile {
                case .blank:
                    // Gamepad Mode: Ryujinx has focus and the game is running.
                    // Post a left click at the current cursor position so macOS
                    // captures / hides the cursor inside the Ryujinx window,
                    // then return early — Cmd+Q must NOT fire here.
                    print("[ControllerManager] 🖱️ Ryujinx in Gamepad Mode. Sending Left Click to capture/hide cursor.")
                    self.postLeftClick()
                    return
                case .desktop:
                    // Desktop Mode: emulation has been stopped (or Ryujinx is
                    // showing its GUI). Fall through to the standard Cmd+Q path
                    // so the user can close the emulator cleanly.
                    print("[ControllerManager] 🛑 Ryujinx in Desktop Mode. Emulation stopped, sending Cmd+Q safely.")
                }
            }

            // ── Universal Sleep Chord (ES-DE / Finder) ────────────────────
            // When ES-DE or Finder is the foreground app, the chord always
            // triggers sleep regardless of the active profile.
            if appName.localizedCaseInsensitiveContains("ES-DE")
                || appName.localizedCaseInsensitiveContains("Finder") {
                print("[ControllerManager] 🌙 '\(appName)' detected. Triggering universal sleep chord.")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                process.arguments = ["sleepnow"]
                try? process.run()
                return // Always exit early to prevent Cmd+Q from firing
            }

            self.postCmdQ()
            // Smart Quit fallback: if the app didn't exit within 1 second
            // (e.g. it showed a "save before quitting?" dialog), force
            // .desktop so the user has immediate mouse access to respond.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                if self.profileManager.currentProfile == .blank {
                    self.profileManager.setProfile(.desktop)
                    print("[ControllerManager] 🟠 Smart Quit fallback → forced .desktop (app still alive after 1s).")
                }
            }
        }

        gamepad.dpad.left.valueChangedHandler = { [weak self] _, _, isPressed in
            guard let self else { return }
            self.isDpadLeftHeld = isPressed
            // Space-switching removed — state tracked for future chord use.
        }

        gamepad.dpad.right.valueChangedHandler = { [weak self] _, _, isPressed in
            guard let self else { return }
            self.isDpadRightHeld = isPressed
            // Space-switching removed — state tracked for future chord use.
        }

        gamepad.dpad.up.valueChangedHandler = { [weak self] _, _, isPressed in
            guard let self else { return }
            self.isDpadUpHeld = isPressed
            // L1 + Menu + D-Pad Up → Escape + force .desktop
            guard isPressed, self.isL1Held, self.isMenuHeld else { return }
            self.postEscKey()
            // Escape Override: unconditionally switch to .desktop so the
            // user has immediate mouse access for whatever settings menu
            // just appeared, regardless of which app is in focus.
            self.profileManager.setProfile(.desktop)
            print("[ControllerManager] 🖥️ Escape override → forced .desktop.")
        }

        // ── L3 + R3 → Manual Profile Toggle (always active) ──────────────────
        // Fires only on the exact frame the *second* button is pressed, so
        // holding both sticks down simultaneously is required — no rapid-fire.
        // leftThumbstickButton / rightThumbstickButton are optional on
        // GCExtendedGamepad (not present on all controller models), so we
        // safe-unwrap with optional chaining.
        gamepad.leftThumbstickButton?.valueChangedHandler = { [weak self] _, _, isPressed in
            guard let self else { return }
            self.isL3Held = isPressed
            if isPressed && self.isR3Held { self.toggleProfile() }
        }

        gamepad.rightThumbstickButton?.valueChangedHandler = { [weak self] _, _, isPressed in
            guard let self else { return }
            self.isR3Held = isPressed
            if isPressed && self.isL3Held { self.toggleProfile() }
        }

        // ── Stubs for future phases ────────────────────────────────────────────
        // gamepad.buttonX.valueChangedHandler          = { ... }
        // gamepad.buttonY.valueChangedHandler          = { ... }
        // gamepad.rightShoulder.valueChangedHandler    = { ... }  // R1
        // gamepad.leftTrigger.valueChangedHandler      = { ... }  // L2
        // gamepad.rightTrigger.valueChangedHandler     = { ... }  // R2
        // gamepad.buttonOptions?.valueChangedHandler   = { ... }  // Select / Minus

        print("[ControllerManager] Input handlers registered for \(controller.vendorName ?? "controller").")
    }

    // MARK: - CGEvent Helpers

    /// Posts Cmd+Q (key-down + key-up) to quit the foreground application.
    /// Chord: L1 + Menu + D-Pad Down.
    ///
    /// Virtual key 0x0C = 'Q'. Both events carry .maskCommand.
    /// Always posting key-up prevents the system from treating ⌘ as stuck.
    /// Toggles the active profile between `.desktop` and `.blank`.
    /// Called by the L3+R3 hardware safety-net chord.
    /// Always dispatches to the main queue because `ProfileManager.setProfile`
    /// mutates a `@Published` property.
    private func toggleProfile() {
        let next: ProfileState = profileManager.currentProfile == .desktop ? .blank : .desktop
        profileManager.setProfile(next)
        print("[ControllerManager] 🔀 Manual profile toggle → \(next.rawValue) (L3+R3).")
    }

    /// Posts a native Escape key-down + key-up pair.
    /// Chord: L1 + Menu + D-Pad Up.
    ///
    /// Uses `CGEventSource(stateID: .hidSystemState)` so macOS treats the
    /// event as a genuine hardware keystroke, bypassing automation guards
    /// that can block events posted with a nil source.
    ///
    /// No modifier flags are set — a bare Escape, exactly as if the user
    /// pressed the physical key.
    private func postEscKey() {
        let escKey: CGKeyCode = 53
        let source = CGEventSource(stateID: .hidSystemState)

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: escKey, keyDown: true),
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: escKey, keyDown: false)
        else {
            print("[ControllerManager] ⚠️  Failed to create Escape CGEvents.")
            return
        }

        // Explicitly clear all modifier flags so no stray Shift/Ctrl/Cmd
        // from the L1+Menu chord contaminates the Escape event.
        keyDown.flags = []
        keyUp.flags   = []

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        print("[ControllerManager] ⎋ ESC posted (L1 + Menu + D-Pad Up).")
    }

    private func postCmdQ() {
        let qKey: CGKeyCode = 0x0C
        postKeyChord(virtualKey: qKey, flags: .maskCommand)
        print("[ControllerManager] 🔑 Cmd+Q posted (L1 + Menu + D-Pad Down).")
    }

    /// Posts a synthetic left-mouse-down + left-mouse-up at the current cursor
    /// position. Used in Ryujinx Gamepad Mode to capture / hide the system
    /// cursor inside the emulator window without quitting the app.
    ///
    /// Position is read from a scratch `CGEvent` (the only public API that
    /// exposes the live HID cursor location without requiring Accessibility
    /// permissions). Falls back to `.zero` if the event cannot be created.
    ///
    /// A 50 ms delay between down and up gives the Window Server time to
    /// process the down event before the up arrives, matching real hardware
    /// click timing.
    private func postLeftClick() {
        let position = CGEvent(source: nil)?.location ?? .zero

        guard
            let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                    mouseCursorPosition: position, mouseButton: .left),
            let mouseUp   = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                    mouseCursorPosition: position, mouseButton: .left)
        else {
            print("[ControllerManager] ⚠️  Failed to create left-click CGEvents.")
            return
        }

        mouseDown.post(tap: .cghidEventTap)
        usleep(50_000)  // 50 ms — lets the Window Server register the down event
        mouseUp.post(tap: .cghidEventTap)
    }

    /// Posts Ctrl+Left or Ctrl+Right to switch macOS Spaces.
    /// Chord: L1 + Menu + D-Pad Left/Right.
    ///
    /// Virtual keys:  Left Arrow = 0x7B  |  Right Arrow = 0x7C
    /// Modifier: .maskControl (Mission Control Space switching).
    private func postCtrlArrow(left: Bool) {
        let arrowKey: CGKeyCode = left ? 0x7B : 0x7C
        postKeyChord(virtualKey: arrowKey, flags: .maskControl)
        print("[ControllerManager] ␣ Ctrl+\(left ? "←" : "→") posted (Space switch).")
    }

    /// Generic key-down + key-up poster with a modifier flag set.
    /// Both events must carry the same flags; missing key-up can leave
    /// modifier keys stuck system-wide.
    private func postKeyChord(virtualKey: CGKeyCode, flags: CGEventFlags) {
        guard
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true),
            let keyUp   = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false)
        else {
            print("[ControllerManager] ⚠️  Failed to create CGEvents for key 0x\(String(virtualKey, radix: 16)).")
            return
        }

        keyDown.flags = flags
        keyUp.flags   = flags

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Cleanup

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
