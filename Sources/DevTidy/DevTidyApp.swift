import SwiftUI
import DevTidyCore

@main
@MainActor
struct DevTidyApp: App {
    @State private var store: DevTidyStore
    @State private var updater: Updater

    init() {
        let settingsStore = SettingsStore()
        let services = DevTidyServices.live(socketOverride: settingsStore.socketOverrideProvider)
        let store = DevTidyStore(services: services, settingsStore: settingsStore)
        // `MenuBarExtra` content is lazy: polling must start here, not when the popover is first opened.
        store.start()
        _store = State(initialValue: store)
        // One updater for the whole process, started now so that Sparkle's scheduled background checks run from launch.
        _updater = State(initialValue: Updater())
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store, updater: updater)
        }
    }
}
