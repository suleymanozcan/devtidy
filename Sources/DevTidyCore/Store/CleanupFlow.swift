import Foundation

/// State machine behind the cleanup sheet. `DevTidyStore.cleanup != nil` ⇒ the sheet is visible.
///
/// Nothing is deleted or killed until `DevTidyStore.confirmCleanup()` is called from the sheet's primary button, and
/// `review` always carries the exact plan (absolute paths via `CacheEntry`, sizes, mode per selection) the user saw.
public enum CleanupFlow: Sendable {
    case planning(forServer: ProcessIdentity?, projectRoot: String)
    case review(plan: CleanupPlan, selections: [String: CleanupSelection], stopFirst: DevServer?)   // keyed by entryID
    case executing(planID: UUID, stoppingServer: Bool)
    case finished(CleanupResult, terminated: TerminationReport?)
    case failed(UserFacingError)

    /// True while the sheet must not be dismissed (a stop or delete is in flight).
    public var isExecuting: Bool {
        if case .executing = self { return true }
        return false
    }
}

/// Pure rules shared by the sheet (button enablement) and the store (guard before acting), so the UI never
/// re-implements `ActivityBlocker.blocks(_:)`.
public enum CleanupRules {
    /// True when `blocker` is one of the processes the stop+clean flow is about to stop itself.
    public static func isBeingStopped(_ blocker: ActivityBlocker, stopFirst: DevServer?) -> Bool {
        guard let stopFirst, blocker.kind != .container, let pid = blocker.pid else { return false }
        return stopFirst.members.contains { $0.identity.pid == pid }
    }

    /// Blockers that block at least one *selected* entry and will not go away by stopping `stopFirst`.
    /// Non-empty ⇒ the primary button is disabled and `confirmCleanup()` refuses.
    public static func unresolvedBlockers(plan: CleanupPlan,
                                          selections: [String: CleanupSelection],
                                          stopFirst: DevServer?) -> [ActivityBlocker] {
        let selected = plan.entries.filter { selections[$0.id] != nil }
        guard !selected.isEmpty else { return [] }
        return plan.blockers.filter { blocker in
            !isBeingStopped(blocker, stopFirst: stopFirst) && selected.contains { blocker.blocks($0.safety) }
        }
    }

    /// Selected entries in plan order (the order the cleaner executes them). The user's "Anladım" travels with every class C
    /// selection, because the cleaner refuses dependencies without it.
    public static func orderedSelections(plan: CleanupPlan, selections: [String: CleanupSelection],
                                         acknowledgedDependencies: Bool = false) -> [CleanupSelection] {
        plan.entries.compactMap { entry in
            guard let selection = selections[entry.id] else { return nil }
            guard entry.safety == .optIn, acknowledgedDependencies else { return selection }
            return CleanupSelection(entryID: selection.entryID, mode: selection.mode, acknowledgedDependencies: true)
        }
    }

    /// Bytes that leave the disk immediately (permanent) vs. only after the Trash is emptied.
    public static func totals(plan: CleanupPlan, selections: [String: CleanupSelection]) -> (permanent: Int64, trash: Int64, hasPartial: Bool) {
        var permanent: Int64 = 0, trash: Int64 = 0
        var partial = false
        for entry in plan.entries {
            guard let selection = selections[entry.id] else { continue }
            let bytes = entry.sizeBytes ?? 0
            if entry.sizeIsPartial { partial = true }
            switch selection.mode {
            case .permanent: permanent += bytes
            case .trash: trash += bytes
            }
        }
        return (permanent, trash, partial)
    }

    /// Default selection for a fresh plan: entries flagged `defaultSelected`, never class C.
    public static func defaultSelections(for plan: CleanupPlan, deleteConditionalPermanently: Bool) -> [String: CleanupSelection] {
        var out: [String: CleanupSelection] = [:]
        for entry in plan.entries where entry.defaultSelected && entry.safety != .optIn {
            out[entry.id] = CleanupSelection(entryID: entry.id, mode: defaultMode(for: entry, deleteConditionalPermanently: deleteConditionalPermanently))
        }
        return out
    }

    /// Class B follows the user's setting (Trash unless they opted into permanent deletion); everything else keeps the catalog default.
    public static func defaultMode(for entry: CacheEntry, deleteConditionalPermanently: Bool) -> DeleteMode {
        if entry.safety == .conditional { return deleteConditionalPermanently ? .permanent : .trash }
        return entry.defaultMode
    }
}
