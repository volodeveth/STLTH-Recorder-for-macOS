import Foundation

/// Repairs CAF files left behind by a crash.
///
/// While a CAF is being written its `data` chunk carries size `-1` ("unknown length");
/// the real size is patched in when the file is closed. A `kill -9` skips that, and
/// although Apple's own stack happily plays such a file, libsndfile and ffmpeg reject
/// it as malformed. Since these recordings are meant to feed an analytics pipeline,
/// the size is rewritten during crash recovery — the audio bytes are never touched.
///
/// CAF layout (Apple "Core Audio Format Specification"): 8-byte file header, then
/// chunks of `[4-byte type][8-byte big-endian size][payload]`.
enum CAFRepair {

    /// - Returns: `true` if the file was modified.
    @discardableResult
    static func repairIfNeeded(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 8 else { return false }

        var offset: UInt64 = 8 // skip 'caff' + version/flags
        while offset + 12 <= fileSize {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 12), header.count == 12 else { return false }

            let type = String(decoding: header[header.startIndex..<header.startIndex + 4], as: UTF8.self)
            let size = header[(header.startIndex + 4)...].reduce(Int64(0)) { ($0 << 8) | Int64($1) }

            let payloadStart = offset + 12

            if type == "data" {
                guard size == -1 else { return false } // already sound
                let realSize = Int64(fileSize - payloadStart)
                guard realSize > 0 else { return false }

                var bigEndian = realSize.bigEndian
                let bytes = withUnsafeBytes(of: &bigEndian) { Data($0) }
                try? handle.seek(toOffset: offset + 4)
                try? handle.write(contentsOf: bytes)
                return true
            }

            guard size > 0 else { return false } // unknown size on a non-data chunk: give up
            offset = payloadStart + UInt64(size)
        }
        return false
    }
}
