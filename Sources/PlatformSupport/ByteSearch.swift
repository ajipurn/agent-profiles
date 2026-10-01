import Foundation

public enum ByteSearch {
    /// First occurrence of `needle` in `count` bytes at `base`, like memmem —
    /// which the Windows C runtime lacks; there the portable scan runs instead.
    public static func find(_ needle: [UInt8], in base: UnsafeRawPointer, count: Int) -> UnsafeRawPointer? {
        #if os(Windows)
        portableFind(needle, in: base, count: count)
        #else
        memmem(base, count, needle, needle.count).map { UnsafeRawPointer($0) }
        #endif
    }

    /// memchr to each candidate first byte, memcmp to confirm. Compiled
    /// everywhere so the tests can hold it to memmem's results.
    static func portableFind(_ needle: [UInt8], in base: UnsafeRawPointer, count: Int) -> UnsafeRawPointer? {
        guard let first = needle.first else { return base }
        var cursor = base
        var left = count
        // Only search where a whole needle still fits.
        while left >= needle.count, let hit = memchr(cursor, Int32(first), left - needle.count + 1) {
            let hit = UnsafeRawPointer(hit)
            if memcmp(hit, needle, needle.count) == 0 { return hit }
            let skip = cursor.distance(to: hit) + 1
            cursor += skip
            left -= skip
        }
        return nil
    }
}
