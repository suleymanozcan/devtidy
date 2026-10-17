import Foundation

extension CacheEntry {
    /// The relative paths `displayPath` lists, one per target. For rules with several possible targets (`dirs`, discovered)
    /// this list is the record of what was offered: sizing and the cleaner only ever narrow to it, never widen.
    var listedRelativePaths: [String] {
        displayPath.components(separatedBy: Self.displaySeparator)
    }
}
