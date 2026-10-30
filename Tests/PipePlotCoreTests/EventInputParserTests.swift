import XCTest
@testable import PipePlotCore

final class EventInputParserTests: XCTestCase {
    func testChunkingCRLFAndFinalUnterminatedLine() {
        var parser = EventInputParser()
        XCTAssertEqual(parser.append(Data("first\r\n  second  \n\nlast".utf8)), [.event("first"), .event("second")])
        XCTAssertEqual(parser.finish(), [.event("last")])
    }

    func testRejectsInvalidUTF8AndNULButContinues() {
        var parser = EventInputParser()
        XCTAssertEqual(parser.append(Data([0x61, 0x00, 0x0a, 0xff, 0x0a, 0x6f, 0x6b, 0x0a])), [
            .rejected("event contains a NUL byte"), .rejected("event is not valid UTF-8"), .event("ok")
        ])
    }

    func testOversizeLineIsDiscardedAsOneAndParserResynchronizes() {
        var parser = EventInputParser()
        let oversized = Data(repeating: 0x61, count: EventInputParser.maximumLineBytes + 1) + Data("\nvalid\n".utf8)
        XCTAssertEqual(parser.append(oversized), [.rejected("event exceeds 65536 UTF-8 bytes"), .event("valid")])
    }

    func testWhitespaceOnlyLinesAreIgnored() {
        var parser = EventInputParser()
        XCTAssertEqual(parser.append(Data(" \t \n\n".utf8)), [])
        XCTAssertEqual(parser.finish(), [])
    }
}
