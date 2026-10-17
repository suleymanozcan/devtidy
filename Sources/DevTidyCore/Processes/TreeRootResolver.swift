import Foundation

/// Pure: resolves, for one listening process, the tree root DevTidy will start signalling from, and whether the whole
/// process group may be signalled with `kill(-pgid)` (design §4.4). All kill-scope rules (K1, K2, K5, K11) start here;
/// `TreeTerminator` re-verifies every one of them against live data at signal time.
struct TreeRootResolver {
    struct Resolution: Sendable {
        let root: ProcessNode
        /// `root.pgid == root.pid`, not DevTidy's own group, and every process of the group (as far as the own-uid
        /// snapshot can see) is `root` or one of its signalable descendants (browser / app-bundle subtrees are not).
        let groupKillEligible: Bool
        /// What may be signalled below `root`, and the browser / app-bundle subtrees that are spared.
        let scope: TreeScope
    }

    /// `{0, 1, selfPID} ∪ ancestors(of: selfPID)`: never a root, never signalled (K1). The ancestor walk is deeper than
    /// the model's default 12 hops on purpose.
    static func protectedPIDs(in snapshot: ProcessSnapshot) -> Set<Int32> {
        var pids: Set<Int32> = [0, 1, snapshot.selfPID]
        for ancestor in snapshot.ancestors(of: snapshot.selfPID, maxHops: 64) { pids.insert(ancestor.pid) }
        return pids
    }

    /// nil when the listener is missing from the snapshot or is DevTidy itself / one of its ancestors.
    ///
    /// `servingPIDs`: every listening process that is a server in this scan (the listener itself always is); they are never
    /// spared for their name alone. `projectAnchors`: the folders the listener's project stands for, namely the project root
    /// and the repository root above it (a monorepo orchestrator at the repo root started the package's server); they decide
    /// whether a runtime that leads the listener's process group belongs to that project (N-6).
    static func resolve(listenerPID: Int32, snapshot: ProcessSnapshot, servingPIDs: Set<Int32> = [],
                        projectAnchors: [String] = []) -> Resolution? {
        guard let listener = snapshot.nodes[listenerPID] else { return nil }
        let protected = Self.protectedPIDs(in: snapshot)
        guard !protected.contains(listener.pid) else { return nil }

        func isAllowedRoot(_ node: ProcessNode) -> Bool {
            guard !protected.contains(node.pid) else { return false }
            guard node.pid == listener.pid || ProcessNames.isLauncher(node) || ProcessNames.isRuntime(node) else { return false }
            guard !ProcessNames.isBrowserOrAppBundle(node) else { return false }
            return !ProcessNames.isShellTerminalIDEOrAgent(node)
        }

        /// The leader's own working directory or its own executable lies inside an anchor (or, without a project, inside the
        /// listener's working directory). A path that merely appears in its argv says nothing about who it is: any tool can
        /// be pointed at a project (F3-7). Nothing is known about a process whose `cwd` and executable say nothing.
        func belongsToProject(_ node: ProcessNode) -> Bool {
            let anchors = projectAnchors.isEmpty ? [listener.workingDirectory].compactMap { $0 } : projectAnchors
            func inside(_ path: String) -> Bool {
                anchors.contains { $0.count > 1 && (path == $0 || path.hasPrefix($0 + "/")) }
            }
            if let cwd = node.workingDirectory, inside(cwd) { return true }
            if let exe = node.executablePath, inside(exe) { return true }
            return false
        }

        var root = listener
        let ancestors = snapshot.ancestors(of: listener.pid, maxHops: 12)

        // 1. The process-group leader (`npm exec` in ENV §5) when it is an allowed ancestor, nothing between the listener
        //    and the leader is a protected process, shell, terminal, IDE, agent, browser or app bundle, and the leader is
        //    either a launcher or a runtime that belongs to the listener's project. An unlisted interactive tool (an agent
        //    run from another directory) that happens to lead the group of a server it started is therefore not a root.
        if listener.pgid != listener.pid,
           let leaderIndex = ancestors.firstIndex(where: { $0.pid == listener.pgid }),
           isAllowedRoot(ancestors[leaderIndex]),
           ProcessNames.isLauncher(ancestors[leaderIndex]) || belongsToProject(ancestors[leaderIndex]),
           ancestors[..<leaderIndex].allSatisfy({
               !protected.contains($0.pid) && !ProcessNames.isShellTerminalIDEOrAgent($0) && !ProcessNames.isBrowserOrAppBundle($0)
           }) {
            root = ancestors[leaderIndex]
        } else {
            // 2. Otherwise climb through launchers (`npm`, `sh -c`, `turbo`, …) only.
            var hops = 0
            while hops < 12, let parent = snapshot.nodes[root.parentPID], parent.pid != root.pid,
                  isAllowedRoot(parent), ProcessNames.isLauncher(parent) {
                root = parent
                hops += 1
            }
        }

        // 3. Group eligibility.
        let scope = TreeScope.of(root: root, in: snapshot, serving: servingPIDs.union([listener.pid]))
        var eligible = root.pgid == root.pid && root.pgid > 1
        if eligible, let ownGroup = snapshot.nodes[snapshot.selfPID]?.pgid, ownGroup == root.pgid { eligible = false }   // K11
        if eligible {
            let tree = Set(scope.members.map(\.pid))
            eligible = snapshot.groupMembers(root.pgid).allSatisfy { tree.contains($0.pid) }
        }
        return Resolution(root: root, groupKillEligible: eligible, scope: scope)
    }
}
