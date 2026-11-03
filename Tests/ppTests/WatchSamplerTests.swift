import XCTest
@testable import pp

final class WatchSamplerTests: XCTestCase {
    func testRepeatedUnterminatedOutputGetsSeparated() throws {
        let sampler = WatchSampler(command: "printf 42", interval: 0.02)
        defer { sampler.stop() }
        var output = Data()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while output.count < 6 && clock.now < deadline {
            if let data = try sampler.next() { output.append(data) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(String(data: output, encoding: .utf8), "42\n42\n")
    }

    func testNonzeroExitIsReported() throws {
        let sampler = WatchSampler(command: "exit 7", interval: 1)
        defer { sampler.stop() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            do { _ = try sampler.next() } catch {
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
        let clock = ContinuousClock()
        let start = clock.now
        sampler.stop()
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
    }

    func testStopKillsDescendantsAndPreventsRestart() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let sampler = WatchSampler(
            command: "echo ready; (sleep 0.5; echo late > \(marker.path)) & wait", interval: 0.02)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var output = Data()
        while !output.contains(0x0a) && clock.now < deadline {
            if let chunk = try sampler.next() { output.append(chunk) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(String(data: output, encoding: .utf8), "ready\n")
        Thread.sleep(forTimeInterval: 0.05)
        sampler.stop()
        sampler.stop()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(try sampler.next())
    }
}
