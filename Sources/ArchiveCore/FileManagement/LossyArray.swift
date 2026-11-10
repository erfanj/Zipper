import Foundation

/// Decodes an array element by element and keeps what it can read.
///
/// Saved lists (presets, history) are decoded with this: with a plain `[Element]`, one entry this
/// version can't read — written by a newer version, or damaged — makes the whole list read as empty,
/// and the next save then overwrites everything the user had.
public struct LossyArray<Element: Decodable>: Decodable {
    public private(set) var elements: [Element] = []
    /// How many entries were skipped because they couldn't be decoded.
    public private(set) var skipped = 0

    private struct Anything: Decodable { init(from decoder: Decoder) throws {} }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(Anything.self)   // step over the unreadable entry
                skipped += 1
            }
        }
    }
}
