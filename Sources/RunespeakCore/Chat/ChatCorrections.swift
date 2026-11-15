import Foundation

public extension Array where Element == ChatEntry {
    /// Puts a new line into the list of chat lines. A line that stands in for earlier ones
    /// (`ChatTracker.corrections`: a message reported while part of it could not be read, said
    /// again once it could) takes the place of the first of them and the others are removed;
    /// any other line goes to the end.
    mutating func place(_ entry: ChatEntry, replacing earlier: [UUID] = []) {
        let places = earlier.compactMap { id in lastIndex { $0.id == id } }.sorted()
        guard let first = places.first else {
            append(entry)
            return
        }
        self[first] = entry
        for index in places.dropFirst().reversed() where index != first { remove(at: index) }
    }
}
