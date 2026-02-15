import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Reads items from stdin using raw ``read(2)`` — no per-line ``String`` allocation.
///
/// A 64 KB reusable read buffer is filled in a loop.  Lines are delimited by
/// ``0x0A`` (``\n``).  Whitespace is trimmed by byte-scanning both ends.
/// Each trimmed line is appended directly into ``ItemCache.buffer`` (the shared
/// ``TextBuffer``) off the actor, then a single lightweight actor hop registers
/// the ``(offset, length)`` window into the ``ChunkList``.  Lines that straddle
/// a chunk boundary are carried over by shifting unprocessed bytes to the front
/// of the read buffer.
actor StdinReader {
    private let cache: ItemCache
    private var isReading = false
    private(set) var isComplete = false

    init(cache: ItemCache) {
        self.cache = cache
    }

    /// Start reading lines from stdin in the background.
    /// Returns immediately so the UI can start while reading continues.
    func startReading() -> Task<Void, Never> {
        guard !isReading else {
            return Task { }
        }

        isReading = true

        // Task.detached: the read loop blocks an OS thread; keep it off the
        // cooperative pool so it cannot starve Swift concurrency.
        return Task.detached {
            await StdinReader.readLoop(cache: self.cache)
            await self.cache.sealAndShrink()
            await self.finishReading()
        }
    }

    /// Read loop.  Bytes are appended directly into ``cache.buffer`` (safe:
    /// ``TextBuffer`` is append-only and single-writer during the read phase).
    /// The actor hop only carries two ``UInt32`` values per line — no array copy.
    private static func readLoop(cache: ItemCache) async {
        let chunkSize  = 64 * 1024          // 64 KB read chunk
        var buf        = [UInt8](repeating: 0, count: chunkSize)
        var carry      = 0                  // bytes left over from previous chunk
        let textBuffer = cache.buffer       // capture once; reference type

        while true {
            // A single line can exceed the default 64 KB chunk.
            // Grow the buffer before reading so we never issue read(..., 0),
            // which would look like EOF and truncate remaining stdin.
            if carry == buf.count {
                buf.append(contentsOf: repeatElement(0, count: buf.count))
            }

            let available = buf.count - carry
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                read(STDIN_FILENO, ptr.baseAddress! + carry, available)
            }
            if n == 0 { break }             // EOF
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            let total = carry + Int(n)

            var lineStart = 0
            for i in 0..<total {
                guard buf[i] == 0x0A else { continue }   // '\n'

                if let (lo, hi) = StdinReader.trimmedRange(buf, start: lineStart, end: i) {
                    // Append trimmed bytes directly into TextBuffer — no actor hop,
                    // no intermediate allocation.
                    let (offset, length) = buf.withUnsafeBufferPointer { ptr in
                        textBuffer.appendRaw(ptr, offset: lo, length: hi - lo)
                    }
                    // Lightweight hop: register the new Item in the ChunkList.
                    await cache.registerItem(offset: offset, length: length)
                }
                lineStart = i + 1
            }

            // Carry incomplete trailing line to next iteration
            carry = total - lineStart
            if carry > 0 && lineStart > 0 {
                buf.withUnsafeMutableBufferPointer { raw in
                    raw.baseAddress!.initialize(
                        from: raw.baseAddress!.advanced(by: lineStart), count: carry)
                }
            }
        }

        // Flush any remaining bytes (last line without trailing newline)
        if carry > 0 {
            if let (lo, hi) = StdinReader.trimmedRange(buf, start: 0, end: carry) {
                let (offset, length) = buf.withUnsafeBufferPointer { ptr in
                    textBuffer.appendRaw(ptr, offset: lo, length: hi - lo)
                }
                await cache.registerItem(offset: offset, length: length)
            }
        }
    }

    /// Return the ``(lo, hi)`` indices of the non-whitespace content within
    /// ``buf[start..<end]``, or ``nil`` if the slice is entirely whitespace.
    @inline(__always)
    private static func trimmedRange(
        _ buf: [UInt8], start: Int, end: Int
    ) -> (Int, Int)? {
        var lo = start
        var hi = end
        while lo < hi && isWhitespace(buf[lo]) { lo += 1 }
        while hi > lo && isWhitespace(buf[hi - 1]) { hi -= 1 }
        return lo < hi ? (lo, hi) : nil
    }

    @inline(__always)
    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A  // SP HT CR LF
    }

    func finishReading() async {
        isComplete = true
    }

    /// Check if reading is complete
    func readingComplete() -> Bool {
        return isComplete
    }
}
