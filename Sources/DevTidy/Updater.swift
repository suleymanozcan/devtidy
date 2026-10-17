import AppKit
import Observation
import Sparkle

/// Owns the single Sparkle updater and mirrors the three values the UI needs into Observation-friendly properties.
/// Sparkle's own `SULastCheckTime` / `SUEnableAutomaticChecks` / `SUAutomaticallyUpdate` defaults stay the source of truth.
@MainActor
@Observable
final class Updater {
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false

    @ObservationIgnored private let reminders = UpdateReminders()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: reminders
        )
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates

        // Sparkle posts KVO changes on the main thread; the handler hops explicitly because it is `@Sendable`.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in self?.canCheckForUpdates = value }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in self?.automaticallyChecksForUpdates = value }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in self?.automaticallyDownloadsUpdates = value }
            },
        ]
    }

    /// User-initiated check: Sparkle always shows its result (update found, up to date, or an error).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        automaticallyChecksForUpdates = enabled
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        automaticallyDownloadsUpdates = enabled
        controller.updater.automaticallyDownloadsUpdates = enabled
    }
}

/// Gentle scheduled update reminders for an `LSUIElement` app.
///
/// Without a Dock icon or an app menu nothing would tell the user that the daily background check found an update, and Sparkle
/// presents scheduled alerts of background apps *behind* other windows. So Sparkle's standard alert is still the UI, but the app is
/// activated right before every update alert, which brings that alert to the front.
///
/// Sparkle declares `SPUStandardUserDriverDelegate` without actor annotations but always calls it on the main thread, so the
/// conformance is `@preconcurrency`: the compiler then checks main-thread isolation at run time instead of rejecting the class.
@MainActor
private final class UpdateReminders: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    /// Opts in to the gentle-reminder API: without it Sparkle logs a warning for background apps and may not show scheduled updates.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows every scheduled update itself (not only those near launch); the reminder is the activation below.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // `false` would mean the app itself shows the update, which never happens here.
        guard handleShowingUpdate else { return }
        NSApp.activate()
    }
}
