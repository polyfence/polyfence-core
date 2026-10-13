import XCTest
@testable import PolyfenceCore

/**
 * Swift mirror of the Kotlin `ZoneMetadataReadTest`: reading one zone's stored
 * metadata back out through `loadZoneData` and `loadZoneName`.
 *
 * Before these, data went in through `saveZone` and only came back out through
 * `loadAllZones`, so a caller holding one zone id had to read and decode every
 * stored zone to answer a question about one of them.
 *
 * Assertions must match Kotlin case for case: both platforms feed the same
 * TypeScript and Dart consumers, so a divergence here is a real bug. The one
 * deliberate difference is the storage layout, noted on the last test.
 */
class ZoneMetadataReadTests: XCTestCase {

    private var persistence: ZonePersistence!

    override func setUp() {
        super.setUp()
        persistence = ZonePersistence()
        // UserDefaults is process-wide, so a previous test's zones would read as
        // this test's starting state.
        persistence.clearAllZones()
    }

    override func tearDown() {
        persistence.clearAllZones()
        super.tearDown()
    }

    // MARK: - loadZoneData

    func testReturnsTheDataSaveZoneStored() {
        persistence.saveZone(zoneId: "z1", zoneName: "Home", zoneData: ["colour": "blue", "radius": 50])

        let data = persistence.loadZoneData(zoneId: "z1")
        XCTAssertNotNil(data)
        XCTAssertEqual("blue", data?["colour"] as? String)
        XCTAssertEqual(50, data?["radius"] as? Int)
    }

    func testReturnsNilForAZoneThatWasNeverSaved() {
        XCTAssertNil(persistence.loadZoneData(zoneId: "nope"))
    }

    func testReturnsNilOnceTheZoneIsRemoved() {
        persistence.saveZone(zoneId: "z1", zoneName: "Home", zoneData: ["colour": "blue"])
        persistence.removeZone(zoneId: "z1")
        XCTAssertNil(persistence.loadZoneData(zoneId: "z1"))
    }

    func testReturnsNilForEveryZoneOnceAllAreCleared() {
        persistence.saveZone(zoneId: "z1", zoneName: "Home", zoneData: ["colour": "blue"])
        persistence.saveZone(zoneId: "z2", zoneName: "Work", zoneData: ["colour": "red"])
        persistence.clearAllZones()
        XCTAssertNil(persistence.loadZoneData(zoneId: "z1"))
        XCTAssertNil(persistence.loadZoneData(zoneId: "z2"))
    }

    func testReadsTheZoneAskedForAndNotANeighbour() {
        persistence.saveZone(zoneId: "z1", zoneName: "Home", zoneData: ["colour": "blue"])
        persistence.saveZone(zoneId: "z2", zoneName: "Work", zoneData: ["colour": "red"])

        XCTAssertEqual("blue", persistence.loadZoneData(zoneId: "z1")?["colour"] as? String)
        XCTAssertEqual("red", persistence.loadZoneData(zoneId: "z2")?["colour"] as? String)
    }

    func testRoundTripsANestedStructureNotJustFlatValues() {
        // The realistic payload: a caller attaching its own object to a zone.
        persistence.saveZone(
            zoneId: "z1",
            zoneName: "Home",
            zoneData: [
                "notes": ["milk", "bread"],
                "meta": ["icon": "house", "pinned": true]
            ]
        )

        let data = persistence.loadZoneData(zoneId: "z1")
        XCTAssertEqual(["milk", "bread"], data?["notes"] as? [String])
        let meta = data?["meta"] as? [String: Any]
        XCTAssertEqual("house", meta?["icon"] as? String)
        XCTAssertEqual(true, meta?["pinned"] as? Bool)
    }

    func testAnEmptyDataMapRoundTripsAsEmptyRatherThanNil() {
        // Absent and "saved with nothing attached" are different answers.
        persistence.saveZone(zoneId: "z1", zoneName: "Home", zoneData: [:])
        let data = persistence.loadZoneData(zoneId: "z1")
        XCTAssertNotNil(data)
        XCTAssertTrue(data?.isEmpty ?? false)
    }

    // MARK: - loadZoneName

    func testReturnsTheNameSaveZoneStored() {
        persistence.saveZone(zoneId: "z1", zoneName: "Home", zoneData: ["colour": "blue"])
        XCTAssertEqual("Home", persistence.loadZoneName(zoneId: "z1"))
    }

    func testReturnsANilNameForAZoneThatWasNeverSaved() {
        XCTAssertNil(persistence.loadZoneName(zoneId: "nope"))
    }

    func testReturnsANilNameOnceTheZoneIsRemoved() {
        persistence.saveZone(zoneId: "z1", zoneName: "Home", zoneData: ["colour": "blue"])
        persistence.removeZone(zoneId: "z1")
        XCTAssertNil(persistence.loadZoneName(zoneId: "z1"))
    }

    func testAnOrphanedNameKeyIsNotAnswered() {
        // Each zone's name has its own key, so a name can outlive the id list
        // that every other read here treats as authoritative. Reading the key
        // alone would answer for a zone this store no longer considers present.
        // Kotlin gets this for free by going through getSavedZones.
        let store = UserDefaults.standard
        store.set("Ghost", forKey: "polyfence_zone_names_ghost")

        XCTAssertNil(persistence.loadZoneName(zoneId: "ghost"))
        XCTAssertNil(persistence.loadZoneData(zoneId: "ghost"))

        store.removeObject(forKey: "polyfence_zone_names_ghost")
    }

    func testOverwritingAZoneWithLessDataLeavesNoStaleFields() {
        // A per-key store is exactly where stale fields survive an overwrite.
        persistence.saveZone(
            zoneId: "z1",
            zoneName: "Home",
            zoneData: ["colour": "blue", "note": "milk", "pinned": true]
        )
        persistence.saveZone(zoneId: "z1", zoneName: "Work", zoneData: ["colour": "red"])

        let data = persistence.loadZoneData(zoneId: "z1")
        XCTAssertEqual("red", data?["colour"] as? String)
        XCTAssertNil(data?["note"], "the previous note must not survive")
        XCTAssertNil(data?["pinned"], "the previous flag must not survive")
        XCTAssertEqual("Work", persistence.loadZoneName(zoneId: "z1"))
    }

    func testAStoredNullComesBackAsNSNullAtEveryDepth() {
        // The iOS half of Kotlin's JSONObject.NULL assertion. The sentinel
        // differs by platform, so a bridge author translating one needs the
        // other pinned rather than described.
        persistence.saveZone(
            zoneId: "z1",
            zoneName: "Home",
            zoneData: [
                "polygon": NSNull(),
                "meta": ["note": NSNull()],
                "list": ["a", NSNull()]
            ]
        )

        let back = persistence.loadZoneData(zoneId: "z1")!
        XCTAssertTrue(back["polygon"] is NSNull)
        XCTAssertTrue((back["meta"] as! [String: Any])["note"] is NSNull)
        XCTAssertTrue((back["list"] as! [Any])[1] is NSNull)
    }

    // MARK: - storage layout

    func testOneUnreadableZoneDoesNotHideAReadableOne() {
        // The Kotlin twin of this test also asserts that loadAllZones loses
        // everything in this situation, because Android keeps all zones in one
        // preferences string wrapped in a single try. iOS gives each zone its
        // own key and catches per zone, so loadAllZones already skips the bad
        // one and keeps the rest. Asserted here so the two platforms' differing
        // behaviour is recorded rather than discovered later.
        persistence.saveZone(zoneId: "good", zoneName: "Home", zoneData: ["colour": "blue"])

        // Write bytes that are not JSON under the key the reader uses.
        let store = UserDefaults.standard
        store.set("not-json".data(using: .utf8), forKey: "polyfence_zones_bad")
        store.set("Broken", forKey: "polyfence_zone_names_bad")
        var ids = store.stringArray(forKey: "polyfence_zones") ?? []
        ids.append("bad")
        store.set(ids, forKey: "polyfence_zones")

        XCTAssertEqual(
            "blue",
            (persistence.loadAllZones()["good"]?.2)?["colour"] as? String,
            "iOS catches per zone, so the readable zone survives loadAllZones"
        )
        XCTAssertEqual("blue", persistence.loadZoneData(zoneId: "good")?["colour"] as? String)
        XCTAssertNil(persistence.loadZoneData(zoneId: "bad"))
    }
}
