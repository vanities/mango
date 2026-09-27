import Foundation

/// UTF-16 text position plus context, independent of font size, columns and screen dimensions.
struct NovelTextAnchor: Codable, Hashable, Sendable {
    var quote: String
    var prefix: String
    var suffix: String
    var offset: Int
    init(quote: String, prefix: String = "", suffix: String = "", offset: Int) {
        self.quote = quote; self.prefix = prefix; self.suffix = suffix; self.offset = offset
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        offset = try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0
    }
}
