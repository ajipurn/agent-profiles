import Foundation
import Testing
@testable import PlatformSupport

struct ByteSearchTests {
    /// Reference answer: offset of the first match, by brute force.
    private func naive(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        return (0...(haystack.count - needle.count)).first { haystack[$0..<$0 + needle.count].elementsEqual(needle) }
    }

    private func offset(_ search: ([UInt8], UnsafeRawPointer, Int) -> UnsafeRawPointer?,
                        _ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        haystack.withUnsafeBytes { buffer in
            search(needle, buffer.baseAddress!, buffer.count).map { buffer.baseAddress!.distance(to: $0) }
        }
    }

    /// The Windows fallback must agree with memmem, edge cases included:
    /// near-misses on the first byte, matches at either end, needles
    /// longer than the haystack.
    @Test func portableScanMatchesBruteForce() {
        let haystacks = ["a", "aaab", "abcabcabd", "\"type\":\"assistant\"\n{\"usage\"", "xxxxxxxxxxab"]
        let needles = ["a", "ab", "abd", "aab", "\"usage\"", "assistant", "zz", "abcabcabdx"]
        for h in haystacks {
            for n in needles {
                let haystack = Array(h.utf8), needle = Array(n.utf8)
                let expected = naive(needle, in: haystack)
                #expect(offset(ByteSearch.portableFind, needle, in: haystack) == expected, "\(n) in \(h)")
                #expect(offset(ByteSearch.find, needle, in: haystack) == expected, "\(n) in \(h)")
            }
        }
    }
}
