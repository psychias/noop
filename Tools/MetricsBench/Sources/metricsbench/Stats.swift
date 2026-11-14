import Foundation

// Stats — the agreement instruments the research files ask for (docs/VALIDATION_PROTOCOL.md R4/R7):
// Bland–Altman bias and limits of agreement, MAE, MAPE, Lin's concordance, Pearson r, and the fraction
// within a tolerance (CP2 at 2 breaths/min). Quantiles use linear interpolation on (n−1)·p, the same
// definition as NumPy's default, so a number here can be re-derived outside Swift.

struct Agreement: CustomStringConvertible {
    let n: Int
    let bias: Double
    let sd: Double
    let loaLow: Double
    let loaHigh: Double
    let mae: Double
    let mape: Double
    let ccc: Double
    let r: Double
    let within: Double   // fraction with |diff| ≤ tolerance

    var description: String {
        n == 0 ? "n=0" :
        String(format: "n=%d bias=%+.2f LoA=[%+.2f, %+.2f] MAE=%.2f MAPE=%.1f%% CCC=%.3f r=%.3f within=%.0f%%",
               n, bias, loaLow, loaHigh, mae, mape * 100, ccc, r, within * 100)
    }
}

enum Stats {
    static func mean(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count) }

    static func sd(_ x: [Double]) -> Double {
        guard x.count >= 2 else { return .nan }
        let m = mean(x)
        return (x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count - 1)).squareRoot()
    }

    static func median(_ x: [Double]) -> Double { quantile(x, 0.5) }

    static func quantile(_ x: [Double], _ p: Double) -> Double {
        guard !x.isEmpty else { return .nan }
        let s = x.sorted()
        let pos = Double(s.count - 1) * p
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let n = min(x.count, y.count)
        guard n >= 2 else { return .nan }
        let mx = mean(Array(x[0..<n])), my = mean(Array(y[0..<n]))
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<n { let dx = x[i] - mx, dy = y[i] - my; sxy += dx * dy; sxx += dx * dx; syy += dy * dy }
        return sxx == 0 || syy == 0 ? .nan : sxy / (sxx * syy).squareRoot()
    }

    /// Lin's concordance correlation coefficient (1989): 2·cov / (var_x + var_y + (μx − μy)²), population
    /// moments.
    static func ccc(_ x: [Double], _ y: [Double]) -> Double {
        let n = min(x.count, y.count)
        guard n >= 2 else { return .nan }
        let mx = mean(Array(x[0..<n])), my = mean(Array(y[0..<n]))
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<n { let dx = x[i] - mx, dy = y[i] - my; sxy += dx * dy; sxx += dx * dx; syy += dy * dy }
        let d = sxx + syy + Double(n) * (mx - my) * (mx - my)
        return d == 0 ? .nan : 2 * sxy / d
    }

    /// Agreement of `estimate` against `reference`, pairwise; `tolerance` feeds `within`.
    static func agreement(estimate: [Double], reference: [Double], tolerance: Double) -> Agreement {
        let pairs = zip(estimate, reference).filter { !$0.0.isNaN && !$0.1.isNaN }
        let e = pairs.map { $0.0 }, r = pairs.map { $0.1 }
        let n = pairs.count
        guard n > 0 else { return Agreement(n: 0, bias: .nan, sd: .nan, loaLow: .nan, loaHigh: .nan, mae: .nan, mape: .nan, ccc: .nan, r: .nan, within: .nan) }
        let d = zip(e, r).map { $0 - $1 }
        let bias = mean(d)
        let s = n >= 2 ? sd(d) : .nan
        let mae = mean(d.map { abs($0) })
        let ape = zip(d, r).compactMap { $1 != 0 ? abs($0) / abs($1) : nil }
        let within = Double(d.filter { abs($0) <= tolerance }.count) / Double(n)
        return Agreement(n: n, bias: bias, sd: s, loaLow: bias - 1.96 * s, loaHigh: bias + 1.96 * s,
                         mae: mae, mape: ape.isEmpty ? .nan : mean(ape), ccc: ccc(e, r), r: pearson(e, r), within: within)
    }

    /// Left-aligned pad to `n` characters (String(format:) has no safe `%s` for Swift strings).
    static func padR(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    static func padL(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

    static func fmt(_ v: Double, _ digits: Int = 2) -> String {
        v.isNaN ? "—" : String(format: "%.\(digits)f", v)
    }
}
