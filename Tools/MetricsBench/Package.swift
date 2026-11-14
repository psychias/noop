// swift-tools-version:5.9
import PackageDescription

// MetricsBench — score NOOP's overnight vitals (HRV windows, RSA respiratory rate, resting HR) against
// reference-grade beat streams and respiration waveforms from public PhysioNet datasets, under the
// R-R sparsity a WHOOP 5.0 actually delivers.
//
// Companion to `Tools/SleepPSG` (sleep staging against polysomnography). Same contract: every dataset
// is a command-line argument, lives outside the tree (`research-data/` is git-ignored), is read-only,
// and no NOOP database or wearer's health data is ever opened. Every report prints its regenerating
// command and run date (docs/VALIDATION_PROTOCOL.md R3).
//
// `swift test` needs no dataset: the self-check corpus is synthetic and pins the WFDB decoder, the
// sparsity simulator, the statistics and the direction-tracking behaviour of the shipped estimators.
let package = Package(
    name: "metricsbench",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/StrandAnalytics"),
        .package(path: "../../Packages/WhoopProtocol"),
    ],
    targets: [
        .executableTarget(name: "metricsbench", dependencies: ["StrandAnalytics", "WhoopProtocol"]),
        .testTarget(name: "metricsbenchTests", dependencies: ["metricsbench"]),
    ]
)
