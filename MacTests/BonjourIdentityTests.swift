import Foundation
import Testing

struct BonjourIdentityTests {
    /// Source/configuration regression evidence, not a Bonjour runtime test.
    @Test func discoveryBindingsShareStandardsCompliantServiceName() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let expression = try NSRegularExpression(pattern: #""(_[A-Za-z0-9-]+\._tcp)""#)
        let expected = "_sldirect._tcp"
        let name = String(expected.split(separator: ".")[0].dropFirst())
        // RFC6335 §5.1 and RFC6763 §7.2: the service name excludes the
        // leading underscore; 1...15 ASCII letters/digits/hyphens, at least
        // one letter, no leading/trailing or consecutive hyphens.
        #expect((1...15).contains(name.utf8.count))
        #expect(name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
            || (48...57).contains($0) || $0 == 45 })
        #expect(name.range(of: "[A-Za-z]", options: .regularExpression) != nil)
        #expect(!name.hasPrefix("-") && !name.hasSuffix("-") && !name.contains("--"))

        for (path, count) in [("Mac/Engine/DirectEngineController.swift", 1),
                              ("Shared/StreamReceiver.swift", 1), ("project.yml", 3)] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            #expect(matches.count == count)
            for match in matches {
                let range = try #require(Range(match.range(at: 1), in: text))
                #expect(String(text[range]) == expected)
            }
        }
    }
}
