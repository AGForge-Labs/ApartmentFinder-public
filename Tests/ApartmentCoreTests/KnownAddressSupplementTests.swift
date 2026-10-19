import XCTest
@testable import ApartmentCore

final class KnownAddressSupplementTests: XCTestCase {
    func testInstalledAddressSnapshotKeepsPrivateStreetsAndReceivesNewPublicAreaBeforeMainLaunch() {
        let result = KnownAddressIndex.supplementalAddresses(installed: ["100 Fictional Private Rd"],
            bundled: ["200 Fictional Public Rd", "210 Fictional Public Rd"])
        XCTAssertEqual(result, ["100 Fictional Private Rd", "200 Fictional Public Rd", "210 Fictional Public Rd"])
    }

    func testEquivalentPublicSpellingDoesNotDuplicateOrReplaceSavedStreetAndSeparateNumbersStayDistinct() {
        let result = KnownAddressIndex.supplementalAddresses(installed: ["100 W Fictional Road"],
            bundled: ["100 West Fictional Rd", "105 W Fictional Rd", "105 West Fictional Road", ""])
        XCTAssertEqual(result, ["100 W Fictional Road", "105 W Fictional Rd"])
    }
}
