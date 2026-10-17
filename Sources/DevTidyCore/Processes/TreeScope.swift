import Foundation

/// The part of a process tree DevTidy may ever signal: the root and its descendants, minus every browser / app-bundle /
/// terminal / IDE / agent subtree (QA F6, N-5). A test driver that launches Chrome, or a dev server that starts an Electron
/// app or somebody's editor or agent session, must not take it down when it is stopped; those subtrees are left alone and
/// reported as `spared`.
///
/// Pure: derived from one snapshot. `TreeTerminator` applies the same predicate when it admits a process, so the set
/// shown in the confirmation and the set that can be signalled never disagree.
struct TreeScope: Sendable {
    /// `root` first, then breadth-first descendants (ascending pid per level), spared subtrees excluded.
    let members: [ProcessNode]
    /// Roots of the cut subtrees. They and everything below them are never signalled.
    let spared: [ProcessNode]

    /// `serving`: pids of the listening processes that make this tree a server (never spared for their name alone, see
    /// `ProcessNames.isSparedBelowRoot`).
    static func of(root: ProcessNode, in snapshot: ProcessSnapshot, serving: Set<Int32>) -> TreeScope {
        var members = [root]
        var spared: [ProcessNode] = []
        var seen: Set<Int32> = [root.pid]
        var queue = snapshot.childPIDs(of: root.pid)
        var index = 0
        while index < queue.count {
            let pid = queue[index]
            index += 1
            guard seen.insert(pid).inserted, let node = snapshot.nodes[pid] else { continue }
            if ProcessNames.isSparedBelowRoot(node, serving: serving) {
                spared.append(node)
                continue
            }
            members.append(node)
            queue.append(contentsOf: snapshot.childPIDs(of: pid))
        }
        return TreeScope(members: members, spared: spared)
    }
}
