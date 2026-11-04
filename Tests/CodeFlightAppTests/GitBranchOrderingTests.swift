import XCTest
@testable import CodeFlightApp

final class GitBranchOrderingTests: XCTestCase {
    func testCurrentBranchMovesToTheTopAndKeepsTheOtherOrder() {
        let branches = ["gjs", "kjs-dev", "master", "mzs", "ugw-dev"]
        XCTAssertEqual(GitBranchOrdering.currentFirst(branches, current: "master"),
                       ["master", "gjs", "kjs-dev", "mzs", "ugw-dev"])
        XCTAssertEqual(GitBranchOrdering.currentFirst(branches, current: "ugw-dev"),
                       ["ugw-dev", "gjs", "kjs-dev", "master", "mzs"])
    }

    func testAlreadyFirstOrAbsentLeavesTheListUntouched() {
        let branches = ["gjs", "kjs-dev", "master"]
        XCTAssertEqual(GitBranchOrdering.currentFirst(branches, current: "gjs"), branches)
        XCTAssertEqual(GitBranchOrdering.currentFirst(branches, current: ""), branches)
        XCTAssertEqual(GitBranchOrdering.currentFirst(branches, current: "deleted-elsewhere"), branches)
        XCTAssertEqual(GitBranchOrdering.currentFirst([], current: "main"), [])
    }

    func testSingleBranchIsUnchanged() {
        XCTAssertEqual(GitBranchOrdering.currentFirst(["main"], current: "main"), ["main"])
    }

    func testSlashNamesAreMatchedLiterally() {
        let branches = ["feature/a", "feature/a-fix", "main"]
        XCTAssertEqual(GitBranchOrdering.currentFirst(branches, current: "feature/a-fix"),
                       ["feature/a-fix", "feature/a", "main"])
    }
}
