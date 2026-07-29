import XCTest
@testable import PolyfenceCore

final class PendingEventsStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polyfence-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testZeroSizeDisablesPersistence() {
        let store = PendingEventsStore(queueSize: 0, rootDir: tempDir)
        let evicted = store.append(["zoneId": "z1", "eventType": "ENTER"])
        XCTAssertEqual(evicted, 0)
        XCTAssertTrue(store.drainAll().isEmpty)
    }

    func testDrainReturnsOldestFirstAndClears() {
        let store = PendingEventsStore(queueSize: 10, rootDir: tempDir)
        store.append(["zoneId": "z1", "eventType": "ENTER", "seq": 1])
        store.append(["zoneId": "z2", "eventType": "EXIT", "seq": 2])
        store.append(["zoneId": "z3", "eventType": "ENTER", "seq": 3])
        let drained = store.drainAll()
        XCTAssertEqual(drained.count, 3)
        XCTAssertEqual((drained[0]["seq"] as? Int), 1)
        XCTAssertEqual((drained[2]["seq"] as? Int), 3)
        XCTAssertTrue(store.drainAll().isEmpty)
    }

    func testEvictionDropsOldestAndIncrementsCount() {
        let store = PendingEventsStore(queueSize: 2, rootDir: tempDir)
        XCTAssertEqual(store.append(["seq": 1]), 0)
        XCTAssertEqual(store.append(["seq": 2]), 0)
        XCTAssertEqual(store.append(["seq": 3]), 1)
        XCTAssertEqual(store.append(["seq": 4]), 1)
        XCTAssertEqual(store.currentDroppedCount(), 2)
        let drained = store.drainAll()
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual((drained[0]["seq"] as? Int), 3)
    }

    func testDropCounterSurvivesAcrossInstances() {
        let a = PendingEventsStore(queueSize: 1, rootDir: tempDir)
        a.append(["seq": 1])
        a.append(["seq": 2])
        XCTAssertEqual(a.currentDroppedCount(), 1)
        let b = PendingEventsStore(queueSize: 1, rootDir: tempDir)
        XCTAssertEqual(b.currentDroppedCount(), 1)
    }

    func testPendingEventsSurviveAcrossInstances() {
        let a = PendingEventsStore(queueSize: 10, rootDir: tempDir)
        a.append(["zoneId": "z1", "eventType": "ENTER"])
        a.append(["zoneId": "z1", "eventType": "EXIT"])
        let b = PendingEventsStore(queueSize: 10, rootDir: tempDir)
        let drained = b.drainAll()
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(drained[0]["eventType"] as? String, "ENTER")
        XCTAssertEqual(drained[1]["eventType"] as? String, "EXIT")
    }

    func testFirstAppendOnFreshInstallActuallyPersists() {
        let store = PendingEventsStore(queueSize: 10, rootDir: tempDir)
        let evicted = store.append(["zoneId": "z1", "eventType": "ENTER"])
        XCTAssertEqual(evicted, 0)
        let readback = PendingEventsStore(queueSize: 10, rootDir: tempDir)
        let drained = readback.drainAll()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0]["eventType"] as? String, "ENTER")
    }

    func testQueueSizeOfOneKeepsOnlyNewest() {
        let store = PendingEventsStore(queueSize: 1, rootDir: tempDir)
        XCTAssertEqual(store.append(["seq": 1]), 0)
        XCTAssertEqual(store.append(["seq": 2]), 1)
        XCTAssertEqual(store.append(["seq": 3]), 1)
        let drained = store.drainAll()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual((drained[0]["seq"] as? Int), 3)
        XCTAssertEqual(store.currentDroppedCount(), 2)
    }

    func testDrainAllReturnsEventsEvenAfterQueueDisabled() {
        let enabled = PendingEventsStore(queueSize: 5, rootDir: tempDir)
        enabled.append(["seq": 1])
        enabled.append(["seq": 2])
        let disabled = PendingEventsStore(queueSize: 0, rootDir: tempDir)
        let drained = disabled.drainAll()
        XCTAssertEqual(drained.count, 2)
    }

    func testConcurrentAppendsSerialiseViaTheQueue() {
        let store = PendingEventsStore(queueSize: 100, rootDir: tempDir)
        let group = DispatchGroup()
        let workers = 8
        let perWorker = 10
        for w in 0..<workers {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<perWorker {
                    store.append(["worker": w, "seq": i])
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + .seconds(5))
        let drained = store.drainAll()
        XCTAssertEqual(drained.count, workers * perWorker)
    }

    func testCorruptLineSkippedOnDrain() {
        let storeDir = tempDir.appendingPathComponent("polyfence-pending-events", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let bytes = "{\"zoneId\":\"a\",\"eventType\":\"ENTER\"}\nNOT_JSON_AT_ALL\n{\"zoneId\":\"b\",\"eventType\":\"EXIT\"}\n"
        try? bytes.data(using: .utf8)?.write(to: storeDir.appendingPathComponent("queue.jsonl"))
        let store = PendingEventsStore(queueSize: 10, rootDir: tempDir)
        let drained = store.drainAll()
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(drained[0]["zoneId"] as? String, "a")
        XCTAssertEqual(drained[1]["zoneId"] as? String, "b")
    }

    func testCorruptDroppedCountFileTreatedAsZero() {
        let storeDir = tempDir.appendingPathComponent("polyfence-pending-events", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try? "not-a-number".data(using: .utf8)?.write(to: storeDir.appendingPathComponent("dropped_count"))
        let store = PendingEventsStore(queueSize: 5, rootDir: tempDir)
        XCTAssertEqual(store.currentDroppedCount(), 0)
    }
}
