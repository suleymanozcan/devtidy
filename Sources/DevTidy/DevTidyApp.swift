import SwiftUI
import DevTidyCore

@main
@MainActor
struct DevTidyApp: App {
    @State private var store: DevTidyStore

    init() {
        let settingsStore = SettingsStore()
        let services = DevTidyServices.live(socketOverride: settingsStore.socketOverrideProvider)
        let store = DevTidyStore(services: services, settingsStore: settingsStore)
        // `MenuBarExtra` content is lazy: polling must start here, not when the popover is first opened.
        store.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
