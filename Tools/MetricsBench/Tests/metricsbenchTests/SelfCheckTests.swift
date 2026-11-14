import XCTest
@testable import metricsbench

/// Every dataset-free check the harness carries, as one XCTest each, so CI (`swift-packages.yml`, tools job)
/// fails on the check that broke rather than on a count. `metricsbench selfcheck` runs the same functions
/// without XCTest.
final class SelfCheckTests: XCTestCase {
    private func assertAll(_ checks: [Check], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(checks.isEmpty, "no checks ran", file: file, line: line)
        for c in checks { XCTAssertTrue(c.ok, "\(c.name): \(c.detail)", file: file, line: line) }
    }
    func testWFDBHeader() { assertAll(SelfCheck.wfdbHeader()) }
    func testWFDBSignals() { assertAll(SelfCheck.wfdbSignals()) }
    func testWFDBAnnotations() { assertAll(SelfCheck.wfdbAnnotations()) }
    func testSparsity() { assertAll(SelfCheck.sparsity()) }
    func testStats() { assertAll(SelfCheck.stats()) }
    func testRespReference() { assertAll(SelfCheck.respReference()) }
    func testRSADirectionTracking() { assertAll(SelfCheck.rsaDirectionTracking()) }
    func testHRVWindows() { assertAll(SelfCheck.hrvWindows()) }
}
