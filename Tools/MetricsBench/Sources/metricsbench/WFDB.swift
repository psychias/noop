import Foundation

// WFDB — a pure reader for the PhysioNet waveform-database format: `.hea` headers, signal files in
// formats 16 / 212 / 80, and MIT-format annotation files.
//
// Written from the public format descriptions (https://www.physionet.org/physiotools/wag/header-5.htm,
// signal-5.htm, annot-5.htm) and checked against the WFDB C library's `annot.c` for the pseudo-annotation
// rules. No code is copied from either; the formats are documented facts.
//
// Only what the benches need is implemented. Anything else (multi-segment records, formats 24/32/310,
// skew, byte offsets) is rejected with an error rather than silently misread.

struct WFDBSignalSpec: Equatable {
    let file: String
    let format: Int
    /// ADC units per physical unit. The header's default (0 or absent) is 200.
    let gain: Double
    /// ADC value corresponding to 0 physical units.
    let baseline: Int
    let units: String
    let description: String
}

struct WFDBHeader: Equatable {
    let record: String
    let fs: Double
    let nSamples: Int
    let signals: [WFDBSignalSpec]
    let comments: [String]
}

struct WFDBAnnotation: Equatable {
    let sample: Int
    let code: Int
    let subtype: Int
    let chan: Int
    let num: Int
    let aux: String?
}

enum WFDBError: Error, CustomStringConvertible {
    case malformedHeader(String)
    case unsupported(String)
    case io(String)
    var description: String {
        switch self {
        case .malformedHeader(let s): return "malformed header: \(s)"
        case .unsupported(let s): return "unsupported: \(s)"
        case .io(let s): return "i/o: \(s)"
        }
    }
}

enum WFDB {
    // MARK: header

    static func parseHeader(_ text: String) throws -> WFDBHeader {
        let lines = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var comments: [String] = []
        var body: [String] = []
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("#") { comments.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)); continue }
            body.append(t)
        }
        guard let first = body.first else { throw WFDBError.malformedHeader("empty") }
        let f = first.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count >= 2 else { throw WFDBError.malformedHeader(first) }
        let record = f[0]
        if record.contains("/") { throw WFDBError.unsupported("multi-segment record \(record)") }
        guard let nsig = Int(f[1]) else { throw WFDBError.malformedHeader("signal count in '\(first)'") }
        // fs may be `250`, `250/0.0333(94)` (counter frequency and base counter); take the part before '/'.
        var fs = 250.0
        if f.count >= 3, let v = Double(f[2].split(separator: "/").first ?? "") { fs = v }
        let nSamples = f.count >= 4 ? (Int(f[3]) ?? 0) : 0
        var specs: [WFDBSignalSpec] = []
        for i in 0..<nsig {
            guard body.count > i + 1 else { throw WFDBError.malformedHeader("expected \(nsig) signal lines") }
            specs.append(try parseSignalLine(body[i + 1]))
        }
        return WFDBHeader(record: record, fs: fs, nSamples: nSamples, signals: specs, comments: comments)
    }

    static func parseSignalLine(_ line: String) throws -> WFDBSignalSpec {
        let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count >= 2 else { throw WFDBError.malformedHeader(line) }
        let file = f[0]
        // format[xN][:skew][+offset]
        var fmtStr = f[1]
        if fmtStr.contains("x") || fmtStr.contains(":") || fmtStr.contains("+") {
            let digits = fmtStr.prefix { $0.isNumber }
            if digits.count != fmtStr.count { throw WFDBError.unsupported("format modifiers in '\(f[1])'") }
            fmtStr = String(digits)
        }
        guard let format = Int(fmtStr) else { throw WFDBError.malformedHeader("format in '\(line)'") }
        // gain[(baseline)][/units]
        var gain = 200.0
        var baseline: Int? = nil
        var units = "mV"
        if f.count >= 3 {
            var g = f[2]
            if let slash = g.firstIndex(of: "/") { units = String(g[g.index(after: slash)...]); g = String(g[..<slash]) }
            if let open = g.firstIndex(of: "("), let close = g.firstIndex(of: ")") {
                baseline = Int(g[g.index(after: open)..<close])
                g = String(g[..<open])
            }
            if let v = Double(g), v != 0 { gain = v }
        }
        let adcZero = f.count >= 5 ? (Int(f[4]) ?? 0) : 0
        // Description is everything after the 8th field (checksum, block size precede it).
        let description = f.count > 8 ? f[8...].joined(separator: " ") : ""
        return WFDBSignalSpec(file: file, format: format, gain: gain, baseline: baseline ?? adcZero,
                              units: units, description: description)
    }

    static func readHeader(dir: URL, record: String) throws -> WFDBHeader {
        let url = dir.appendingPathComponent(record + ".hea")
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .isoLatin1) else { throw WFDBError.io("cannot read \(url.path)") }
        return try parseHeader(text)
    }

    // MARK: signals

    /// Physical-unit samples for the requested signal indexes (all when nil). Signals that share a file are
    /// interleaved sample by sample; a file is decoded once. Only formats 16, 212 and 80 are supported.
    static func readSignals(dir: URL, header: WFDBHeader, only: Set<Int>? = nil) throws -> [Int: [Double]] {
        var out: [Int: [Double]] = [:]
        let wanted = only ?? Set(0..<header.signals.count)
        // Group signal indexes by file, preserving header order within a file.
        var byFile: [(file: String, indexes: [Int])] = []
        for (i, s) in header.signals.enumerated() {
            if let k = byFile.firstIndex(where: { $0.file == s.file }) { byFile[k].indexes.append(i) }
            else { byFile.append((s.file, [i])) }
        }
        for group in byFile where !wanted.isDisjoint(with: group.indexes) {
            let url = dir.appendingPathComponent(group.file)
            guard let data = FileManager.default.contents(atPath: url.path) else { throw WFDBError.io("cannot read \(url.path)") }
            let formats = Set(group.indexes.map { header.signals[$0].format })
            guard formats.count == 1, let format = formats.first else { throw WFDBError.unsupported("mixed formats in \(group.file)") }
            let raw: [Int]
            switch format {
            case 16: raw = decode16(data)
            case 212: raw = decode212(data)
            case 80: raw = decode80(data)
            default: throw WFDBError.unsupported("signal format \(format) in \(group.file)")
            }
            let nsig = group.indexes.count
            let frames = raw.count / nsig
            for (slot, idx) in group.indexes.enumerated() where wanted.contains(idx) {
                let spec = header.signals[idx]
                var v = [Double](repeating: 0, count: frames)
                for t in 0..<frames { v[t] = Double(raw[t * nsig + slot] - spec.baseline) / spec.gain }
                out[idx] = v
            }
        }
        return out
    }

    /// Format 16: two's-complement 16-bit little-endian samples.
    static func decode16(_ data: Data) -> [Int] {
        let n = data.count / 2
        var out = [Int](repeating: 0, count: n)
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let v = Int(p[2 * i]) | (Int(p[2 * i + 1]) << 8)
                out[i] = v >= 0x8000 ? v - 0x10000 : v
            }
        }
        return out
    }

    /// Format 212: pairs of 12-bit two's-complement samples packed into three bytes; the first sample
    /// takes byte 0 plus the low nibble of byte 1, the second takes byte 2 plus the high nibble of byte 1.
    static func decode212(_ data: Data) -> [Int] {
        let triplets = data.count / 3
        let tail = data.count % 3
        var out: [Int] = []
        out.reserveCapacity(triplets * 2 + 1)
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for i in 0..<triplets {
                let b0 = Int(p[3 * i]), b1 = Int(p[3 * i + 1]), b2 = Int(p[3 * i + 2])
                var s1 = b0 | ((b1 & 0x0F) << 8)
                var s2 = b2 | ((b1 & 0xF0) << 4)
                if s1 >= 0x800 { s1 -= 0x1000 }
                if s2 >= 0x800 { s2 -= 0x1000 }
                out.append(s1); out.append(s2)
            }
            if tail >= 2 {   // a final unpaired sample
                let b0 = Int(p[3 * triplets]), b1 = Int(p[3 * triplets + 1])
                var s1 = b0 | ((b1 & 0x0F) << 8)
                if s1 >= 0x800 { s1 -= 0x1000 }
                out.append(s1)
            }
        }
        return out
    }

    /// Format 80: 8-bit offset-binary samples (value − 128).
    static func decode80(_ data: Data) -> [Int] {
        data.map { Int($0) - 128 }
    }

    // MARK: annotations

    static let skipCode = 59, numCode = 60, subCode = 61, chnCode = 62, auxCode = 63

    /// QRS annotation codes that mark a beat (ecgcodes.h: NORMAL…UNKNOWN, BBB, PFUS, RONT, plus 34/35
    /// which older annotators used for beats). `NORMAL` (1) alone defines an NN interval.
    static let beatCodes: Set<Int> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 25, 34, 35, 38, 41]
    static let normalBeat = 1

    /// MIT-format annotation stream: 16-bit little-endian words, A = word >> 10, I = word & 0x3FF.
    /// A < 59 is an annotation whose time is the running sum of every I so far; A ≥ 59 is a
    /// pseudo-annotation that modifies the annotation just read (SUB/CHN/NUM/AUX) or adds a long interval
    /// to the time of the NEXT one (SKIP: 4 bytes, high 16-bit word first, each word little-endian).
    /// `num` and `chan` persist until changed; `subtype` and `aux` apply to one annotation. A zero word ends
    /// the file.
    static func parseAnnotations(_ data: Data) -> [WFDBAnnotation] {
        var out: [WFDBAnnotation] = []
        var time = 0
        var num = 0, chan = 0
        var i = 0
        let n = data.count
        func word(_ at: Int) -> Int { Int(data[at]) | (Int(data[at + 1]) << 8) }
        while i + 1 < n {
            let w = word(i); i += 2
            if w == 0 { break }
            let a = w >> 10, inc = w & 0x3FF
            switch a {
            case skipCode:
                guard i + 3 < n else { return out }
                let hi = word(i), lo = word(i + 2); i += 4
                var v = (hi << 16) | lo
                if v >= 0x8000_0000 { v -= 0x1_0000_0000 }
                time += v
            case numCode: num = inc; patchLast(&out) { WFDBAnnotation(sample: $0.sample, code: $0.code, subtype: $0.subtype, chan: $0.chan, num: num, aux: $0.aux) }
            case subCode: patchLast(&out) { WFDBAnnotation(sample: $0.sample, code: $0.code, subtype: inc, chan: $0.chan, num: $0.num, aux: $0.aux) }
            case chnCode: chan = inc; patchLast(&out) { WFDBAnnotation(sample: $0.sample, code: $0.code, subtype: $0.subtype, chan: chan, num: $0.num, aux: $0.aux) }
            case auxCode:
                let len = w & 0xFF
                guard i + len <= n else { return out }
                let bytes = data[i..<(i + len)]
                let s = String(decoding: bytes, as: UTF8.self)
                i += len + (len & 1)   // an odd length is padded to the next word
                patchLast(&out) { WFDBAnnotation(sample: $0.sample, code: $0.code, subtype: $0.subtype, chan: $0.chan, num: $0.num, aux: s) }
            default:
                time += inc
                out.append(WFDBAnnotation(sample: time, code: a, subtype: 0, chan: chan, num: num, aux: nil))
            }
        }
        return out
    }

    private static func patchLast(_ out: inout [WFDBAnnotation], _ f: (WFDBAnnotation) -> WFDBAnnotation) {
        guard let last = out.last else { return }
        out[out.count - 1] = f(last)
    }

    static func readAnnotations(dir: URL, record: String, annotator: String) throws -> [WFDBAnnotation] {
        let url = dir.appendingPathComponent(record + "." + annotator)
        guard let data = FileManager.default.contents(atPath: url.path) else { throw WFDBError.io("cannot read \(url.path)") }
        return parseAnnotations(data)
    }

    /// Record names from a PhysioNet `RECORDS` file (one per line, comments and blanks ignored).
    static func records(dir: URL) throws -> [String] {
        let url = dir.appendingPathComponent("RECORDS")
        guard let data = FileManager.default.contents(atPath: url.path), let text = String(data: data, encoding: .utf8) else {
            throw WFDBError.io("cannot read \(url.path)")
        }
        return text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// The directory at or under `root` (depth ≤ 2) that holds a `RECORDS` file — the extracted PhysioNet
    /// archive wraps its files in one long-named directory, and either level may be passed.
    static func findRecordsDir(_ root: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("RECORDS").path) { return root }
        guard let kids = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for k in kids.sorted(by: { $0.path < $1.path }) {
            if fm.fileExists(atPath: k.appendingPathComponent("RECORDS").path) { return k }
            if let kk = try? fm.contentsOfDirectory(at: k, includingPropertiesForKeys: nil) {
                for g in kk where fm.fileExists(atPath: g.appendingPathComponent("RECORDS").path) { return g }
            }
        }
        return nil
    }
}
