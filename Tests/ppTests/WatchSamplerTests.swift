import XCTest
@testable import pp

final class WatchSamplerTests: XCTestCase {
    func testRepeatedUnterminatedOutputGetsSeparated() throws {
        let sampler = WatchSampler(command: "printf 42", interval: 0.02)
        defer { sampler.stop() }
        var output = Data()
        let deadline = Date().addingTimeInterval(3)
        while output.count < 6 && Date() < deadline {
            if let data = try sampler.next() { output.append(data) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(String(data: output, encoding: .utf8), "42\n42\n")
    }

    func testNonzeroExitIsReported() throws {
        let sampler = WatchSampler(command: "exit 7", interval: 1)
        defer { sampler.stop() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            do { _ = try sampler.next() }
            catch {
                XCTAssertTrue(error.localizedDescription.contains("status 7"))
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTFail("command failure was not reported")
    }

    func testStopTerminatesRunningCommandPromptly() throws {
        let sampler = WatchSampler(command: "sleep 30", interval: 1)
        _ = try sampler.next()
        let start = Date()
        sampler.stop()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
