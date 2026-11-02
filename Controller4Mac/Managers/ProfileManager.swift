// ProfileManager.swift
// Controller4Mac
//
// Phase 6: Robust multi-layer process detection for ES-DE subprocesses.
//
// Responsibilities:
//   1. Owns the current ProfileState (.desktop / .blank).
//   2. Watches NSWorkspace notifications to switch profiles automatically
//      when a game / emulator takes focus.
//   3. Uses a three-tier detection chain so emulators launched as subprocesses
//      (e.g. Ryujinx spawned by ES-DE) are still detected reliably.
//
// Detection chain (evaluated in order, first match wins):
//   Tier 1 — Bundle ID exact match  (fastest; works for .app bundles)
//   Tier 2 — localizedName fuzzy    (catches "Ryujinx (Headless)" variants)
//   Tier 3 — executableURL fuzzy    (catches CLI wrappers: "ryujinx-bin", etc.)
//
// ES-DE safety net:
//   If the activating app is ES-DE itself (detected by bundle ID prefix OR name),
//   the profile stays .desktop so the user can navigate the launcher with the
//   mouse/cursor. The safety net is evaluated BEFORE the emulator checks.
//
// Input gating:
//   ControllerManager reads `profileManager.currentProfile` before forwarding
//   each input to MouseSimulationManager. If the profile is .blank, inputs
//   are silently dropped so the emulator can read the gamepad natively.

import Foundation
import AppKit // NSWorkspace
import Combine

// MARK: - Profile State

/// The two operating modes of Controller4Mac.
///
/// - `desktop`: Full remapping active — thumbstick drives the cursor,
///              face buttons fire mouse clicks.
/// - `blank`:   All remapping suppressed. The gamepad is passed through
///              to whatever application has focus (e.g. an emulator).
enum ProfileState: String, CaseIterable {
    case desktop = "Desktop"
    case blank   = "Blank"
}

// MARK: - ProfileManager

final class ProfileManager: ObservableObject {

    // MARK: - Published State

    /// The currently active profile. Observed by ControllerManager (for gating)
    /// and by ContentView (for display).
    @Published private(set) var currentProfile: ProfileState = .desktop

    // MARK: - Detection Tables

    /// Fuzzy name fragments matched with `.localizedCaseInsensitiveContains`
    /// against both `localizedName` and `executableURL.lastPathComponent`.
    /// Add entries here to pick up new emulators without changing any logic.
    @Published var gameTargets: [String] = [
        // ── Launchers ───────────────────────────────────────────────────────
        "ES-DE",
        "EmulationStation",
        "ES Desktop Edition",
        // ── Emulators ───────────────────────────────────────────────────────
        "Ryujinx",
        "Dolphin",
        "dolphin-emu",
        "PPSSPP",
        "OpenEmu",
        "RetroArch",
        "melonDS",
        "DeSmuME",
        "mGBA",
        "PCSX2",
        "rpcs3",
        "Cemu",
        "Xemu",
    ]

    /// Known emulator Bundle IDs for Tier 1 exact matching.
    /// Exact matches are faster and more reliable than fuzzy string search
    /// when the app is launched as a proper .app bundle.
    private let emulatorBundleIDs: Set<String> = [
        // ES-DE / EmulationStation
        "com.es-de.es-de",
        "com.antigravity.es-de",
        "org.es-de.es-de",
        "com.emulationstation.emulationstation",
        // Nintendo Switch
        "org.ryujinx.Ryujinx",
        "com.masagrator.RyujinxBin",
        // GameCube / Wii
        "org.dolphin-emu.dolphin",
        // PSP
        "com.ppsspp.ppsspp",
        // Multi-system
        "org.openemu.OpenEmu",
        "com.libretro.RetroArch",
        // DS / GBA
        "fr.nicowillis.melonds",
    ]

    /// Kept empty — ES-DE is now treated as a blank target, not a safe launcher.
    /// These arrays are preserved so the safety-net evaluation path in
    /// handleAppActivation compiles unchanged (it short-circuits immediately
    /// when both arrays are empty, adding zero overhead).
    private let desktopSafeBundlePrefixes: [String] = []
    private let desktopSafeNames:          [String] = []

    // MARK: - Private

    private var observers: [NSObjectProtocol] = []

    // MARK: - Init / Deinit

    init() {
        subscribeToWorkspaceNotifications()
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    // MARK: - Public API

    /// Manually force a profile. Useful for a UI toggle button or a future
    /// menu-bar switcher. Prints to console so the developer can verify.
    func setProfile(_ profile: ProfileState) {
        guard profile != currentProfile else { return }
        DispatchQueue.main.async {
            self.currentProfile = profile
            print("[ProfileManager] Profile → \(profile.rawValue)")
        }
    }

    // MARK: - Workspace Observation

    private func subscribeToWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.handleAppActivation(app)
        }
        observers.append(token)
    }

    private func handleAppActivation(_ app: NSRunningApplication?) {
        guard let app else { return }

        let name       = app.localizedName ?? ""
        let bundleID   = app.bundleIdentifier ?? ""
        let execName   = app.executableURL?.lastPathComponent ?? ""

        // ────────────────────────────────────────────────────────────
        // ES-DE SAFETY NET
        // Evaluated first — if this is the launcher itself, always .desktop.
        // ────────────────────────────────────────────────────────────
        let isSafeLauncher =
            desktopSafeBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) ||
            desktopSafeNames.contains(where: { name.localizedCaseInsensitiveCompare($0) == .orderedSame })

        if isSafeLauncher {
            applyProfile(.desktop, reason: "ES-DE/launcher safety net (\(name))")
            return
        }

        // ────────────────────────────────────────────────────────────
        // TIER 1 — Bundle ID exact match
        // ────────────────────────────────────────────────────────────
        if !bundleID.isEmpty, emulatorBundleIDs.contains(bundleID) {
            applyProfile(.blank, reason: "bundle ID match: \(bundleID)")
            return
        }

        // ────────────────────────────────────────────────────────────
        // TIER 2 — localizedName fuzzy contains
        // Catches "Ryujinx (Headless)", "Dolphin 5.0", etc.
        // ────────────────────────────────────────────────────────────
        if !name.isEmpty, let match = gameTargets.first(where: { name.localizedCaseInsensitiveContains($0) }) {
            applyProfile(.blank, reason: "name fuzzy match: '\(name)' ⊃ '\(match)'")
            return
        }

        // ────────────────────────────────────────────────────────────
        // TIER 3 — executableURL.lastPathComponent fuzzy contains
        // Final fallback for CLI wrappers ("ryujinx-bin"), AppImage runners,
        // or apps launched by ES-DE with no bundle metadata.
        // ────────────────────────────────────────────────────────────
        if !execName.isEmpty, let match = gameTargets.first(where: { execName.localizedCaseInsensitiveContains($0) }) {
            applyProfile(.blank, reason: "exec fuzzy match: '\(execName)' ⊃ '\(match)'")
            return
        }

        // No tier matched — treat as a normal desktop app.
        applyProfile(.desktop, reason: name.isEmpty ? "(unknown)" : name)
    }

    // MARK: - Private Helpers

    /// Applies `profile` only if it differs from the current value, then logs
    /// the reason string so detection is fully traceable in the Xcode console.
    private func applyProfile(_ profile: ProfileState, reason: String) {
        guard profile != currentProfile else { return }
        currentProfile = profile
        print("[ProfileManager] \(profile == .blank ? "🎮" : "🖥️") Profile → \(profile.rawValue) (\(reason))")
    }
}
