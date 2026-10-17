import Foundation
import Testing
@testable import DevTidyCore

@MainActor
struct SettingsStoreTests {
    private func makeStore(initial: Data? = nil) -> (SettingsStore, S4MemoryStorage) {
        let storage = S4MemoryStorage(initial: initial)
        return (SettingsStore(storage: storage, homeDirectory: "/tmp/s4home"), storage)
    }

    @Test func defaultsWhenNothingIsStored() {
        let (store, _) = makeStore()
        #expect(store.load() == DevTidySettings())
        let defaults = store.load()
        #expect(defaults.includeDependencies == false)
        #expect(defaults.deleteConditionalPermanently == false)
        #expect(defaults.serverIdleMinutes == 30)
        #expect(defaults.containerIdleMinutes == 15)
        #expect(defaults.buildsMaxDepth == 4)
    }

    @Test func roundTrip() {
        let (store, storage) = makeStore()
        var settings = DevTidySettings()
        settings.scanRoots = ["/tmp/s4home/dev", "/tmp/s4home/work"]
        settings.buildsMaxDepth = 5
        settings.includeDependencies = true
        settings.deleteConditionalPermanently = true
        settings.serverIdleMinutes = 45
        settings.containerIdleMinutes = 10
        settings.idleCPUPercent = 2.5
        settings.showOtherListeners = true
        settings.menuBarShowsMemory = false
        settings.dockerSocketOverride = "/tmp/docker.sock"
        store.save(settings)
        #expect(storage.stored != nil)
        let reloaded = SettingsStore(storage: storage, homeDirectory: "/tmp/s4home").load()
        #expect(reloaded == settings)
    }

    @Test func badJSONFallsBackToDefaults() {
        let (store, _) = makeStore(initial: Data("{ not json".utf8))
        #expect(store.load() == DevTidySettings())
        let (wrongShape, _) = makeStore(initial: Data("[1,2,3]".utf8))
        #expect(wrongShape.load() == DevTidySettings())
    }

    @Test func emptyScanRootsExpandToDeveloperUnderTheInjectedHome() {
        let (store, _) = makeStore()
        #expect(store.effectiveScanRoots(for: DevTidySettings()) == ["/tmp/s4home/developer"])
    }

    @Test func tildeRootsAreExpandedAndDeduplicated() {
        let (store, _) = makeStore()
        var settings = DevTidySettings()
        settings.scanRoots = ["~/dev", "/tmp/s4home/dev", "~", " /abs/path ", ""]
        #expect(store.effectiveScanRoots(for: settings) == ["/tmp/s4home/dev", "/tmp/s4home", "/abs/path"])
    }

    @Test func saveClampsOutOfRangeValues() {
        let (store, storage) = makeStore()
        var settings = DevTidySettings()
        settings.buildsMaxDepth = 99
        settings.serverIdleMinutes = 0
        settings.containerIdleMinutes = -3
        settings.idleCPUPercent = -1
        store.save(settings)
        let reloaded = SettingsStore(storage: storage, homeDirectory: "/tmp/s4home").load()
        #expect(reloaded.buildsMaxDepth == 6)
        #expect(reloaded.serverIdleMinutes == 1)
        #expect(reloaded.containerIdleMinutes == 1)
        #expect(reloaded.idleCPUPercent == 0)
        var low = DevTidySettings()
        low.buildsMaxDepth = 0
        store.save(low)
        #expect(SettingsStore(storage: storage, homeDirectory: "/tmp/s4home").load().buildsMaxDepth == 2)
    }

    @Test func blankSocketOverrideBecomesNil() {
        let (store, storage) = makeStore()
        var settings = DevTidySettings()
        settings.dockerSocketOverride = "   "
        store.save(settings)
        #expect(SettingsStore(storage: storage, homeDirectory: "/tmp/s4home").load().dockerSocketOverride == nil)
    }

    @Test func socketOverrideProviderTracksLoadAndSave() {
        let (store, _) = makeStore()
        let provider = store.socketOverrideProvider
        #expect(provider() == nil)
        var settings = DevTidySettings()
        settings.dockerSocketOverride = "/tmp/a.sock"
        store.save(settings)
        #expect(provider() == "/tmp/a.sock")
        settings.dockerSocketOverride = nil
        store.save(settings)
        #expect(provider() == nil)
    }
}
