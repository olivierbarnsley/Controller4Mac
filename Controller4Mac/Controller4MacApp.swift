// Controller4MacApp.swift
// Controller4Mac
//
// Phase 4: Converted to a MenuBarExtra background utility.
// No Dock icon, no Cmd+Tab entry (requires LSUIElement in Info.plist).
// The menu bar icon reflects live controller + accessibility state.

import SwiftUI

@main
struct Controller4MacApp: App {

    // MARK: - Managers
    //
    // All three managers are initialised in init() so ProfileManager can be
    // constructed first and passed into ControllerManager as a dependency.

    @StateObject private var accessibilityManager: AccessibilityManager
    @StateObject private var profileManager: ProfileManager
    @StateObject private var controllerManager: ControllerManager

    // MARK: - Init

    init() {
        let pm = ProfileManager()
        _profileManager       = StateObject(wrappedValue: pm)
        _controllerManager    = StateObject(wrappedValue: ControllerManager(profileManager: pm))
        _accessibilityManager = StateObject(wrappedValue: AccessibilityManager())
    }

    // MARK: - Scene

    var body: some Scene {
        // MenuBarExtra replaces WindowGroup entirely.
        // `isInserted: true` keeps the app alive in the background with no window.
        // The label closure drives the dynamic menu bar icon.
        MenuBarExtra {
            // The popover content — our compact status panel.
            MenuBarContentView()
                .environmentObject(accessibilityManager)
                .environmentObject(profileManager)
                .environmentObject(controllerManager)
                .onAppear {
                    // Re-check permission every time the menu opens so the
                    // status is always fresh without a timer running 24/7.
                    accessibilityManager.checkPermission()
                }
        } label: {
            // Dynamic icon: filled gamecontroller when all is well,
            // exclamationmark variant when Accessibility is denied.
            MenuBarIconView()
                .environmentObject(accessibilityManager)
                .environmentObject(controllerManager)
        }
        .menuBarExtraStyle(.window) // Renders as a floating panel, not a native menu list.
    }
}

// MARK: - Menu Bar Icon

/// The live icon rendered in the system menu bar.
/// Uses a label so we can show both an SF Symbol and an optional badge.
private struct MenuBarIconView: View {
    @EnvironmentObject private var accessibility: AccessibilityManager
    @EnvironmentObject private var controller: ControllerManager

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
            // Small dot to the right of the icon shows controller connectivity.
            if controller.isConnected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
            }
        }
    }

    /// Switch between a normal and alert icon based on permission state.
    private var iconName: String {
        if !accessibility.isGranted { return "gamecontroller.fill" }
        return "gamecontroller.fill"
    }
}
