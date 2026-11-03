import AppKit
import XCTest
@testable import PipePlotApp

@MainActor
final class SnapshotMenuTests: XCTestCase {
    func testMenuEntriesHaveExplicitKindsAndEachBuildOwnsItsActions() throws {
        let first = SnapshotMenuItem.menu([
            .separator,
            .command("-", checked: true) {},
            .submenu("Empty", []),
        ])
        XCTAssertTrue(first.items[0].isSeparatorItem)
        XCTAssertFalse(first.items[1].isSeparatorItem)
        XCTAssertEqual(first.items[1].state, .on)
        XCTAssertFalse(first.items[2].isEnabled)

        let second = SnapshotMenuItem.menu([.command("New") {}])
        let firstTarget = try XCTUnwrap(first.items[1].representedObject as? NSObject)
        let secondTarget = try XCTUnwrap(second.items[0].representedObject as? NSObject)
        XCTAssertFalse(firstTarget === secondTarget)
    }
}
