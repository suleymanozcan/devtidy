import Foundation
import Testing
@testable import DevTidyCore

struct IdleTrackerTests {
    private let t0 = S4.t0
    private let threshold: TimeInterval = 30 * 60

    private func sample(active: Bool, age: TimeInterval = 60) -> [String: IdleSample] {
        ["a": IdleSample(isActive: active, age: age)]
    }

    @Test func inactiveFor29MinutesIsStillActiveAnd30MinutesIsIdle() {
        var tracker = IdleTracker<String>()
        _ = tracker.update(sample(active: true), threshold: threshold, now: t0)
        let at29 = tracker.update(sample(active: false), threshold: threshold, now: t0.addingTimeInterval(29 * 60))
        #expect(at29["a"] == .active)
        let at30 = tracker.update(sample(active: false), threshold: threshold, now: t0.addingTimeInterval(30 * 60))
        #expect(at30["a"] == .idle)
        #expect(at30["a"]?.isFlagged == true)
    }

    @Test func neverActiveButOldIsProbablyIdleOnFirstTickThenIdleAfterObservedWindow() {
        var tracker = IdleTracker<String>()
        let age: TimeInterval = 3 * 3_600
        let first = tracker.update(sample(active: false, age: age), threshold: threshold, now: t0)
        #expect(first["a"] == .probablyIdle)
        #expect(first["a"]?.isFlagged == true)
        let later = tracker.update(sample(active: false, age: age), threshold: threshold, now: t0.addingTimeInterval(29 * 60))
        #expect(later["a"] == .probablyIdle)
        let observed = tracker.update(sample(active: false, age: age), threshold: threshold, now: t0.addingTimeInterval(30 * 60))
        #expect(observed["a"] == .idle)
    }

    @Test func youngResourceIsNeverFlaggedInsideTheWindow() {
        var tracker = IdleTracker<String>()
        let states = tracker.update(sample(active: false, age: 5 * 60), threshold: threshold, now: t0)
        #expect(states["a"] == .active)
        #expect(states["a"]?.isFlagged == false)
    }

    @Test func activityResetsTheClock() {
        var tracker = IdleTracker<String>()
        _ = tracker.update(sample(active: false, age: 3_600), threshold: threshold, now: t0)
        let idle = tracker.update(sample(active: false, age: 3_600), threshold: threshold, now: t0.addingTimeInterval(31 * 60))
        #expect(idle["a"] == .idle)
        let busy = tracker.update(sample(active: true, age: 3_600), threshold: threshold, now: t0.addingTimeInterval(32 * 60))
        #expect(busy["a"] == .active)
        // 29 minutes after the burst it is quiet again, but not yet idle.
        let quiet = tracker.update(sample(active: false, age: 3_600), threshold: threshold, now: t0.addingTimeInterval(32 * 60 + 29 * 60))
        #expect(quiet["a"] == .active)
        let idleAgain = tracker.update(sample(active: false, age: 3_600), threshold: threshold, now: t0.addingTimeInterval(32 * 60 + 30 * 60))
        #expect(idleAgain["a"] == .idle)
    }

    @Test func vanishedKeysAreDroppedAndStartOverWhenTheyReturn() {
        var tracker = IdleTracker<String>()
        _ = tracker.update(sample(active: false, age: 3_600), threshold: threshold, now: t0)
        let gone = tracker.update([:], threshold: threshold, now: t0.addingTimeInterval(60))
        #expect(gone.isEmpty)
        // Returns 40 minutes later: its first-seen time is "now", so it is not `.idle` yet (only probably idle by age).
        let back = tracker.update(sample(active: false, age: 3_600), threshold: threshold, now: t0.addingTimeInterval(40 * 60))
        #expect(back["a"] == .probablyIdle)
    }

    @Test func keysAreTrackedIndependently() {
        var tracker = IdleTracker<String>()
        let samples = ["busy": IdleSample(isActive: true, age: 7_200), "quiet": IdleSample(isActive: false, age: 7_200)]
        let states = tracker.update(samples, threshold: threshold, now: t0)
        #expect(states["busy"] == .active)
        #expect(states["quiet"] == .probablyIdle)
    }
}
