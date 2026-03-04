import XCTest
@testable import mslCore

final class InstanceRuntimeRegistryTests: XCTestCase {
    func testContextIsScopedByInstanceName() {
        let registry = InstanceRuntimeRegistry()
        let ubuntuA = registry.context(for: "ubuntu")
        let ubuntuB = registry.context(for: "ubuntu")
        let alpine = registry.context(for: "alpine")

        XCTAssertTrue(ubuntuA === ubuntuB)
        XCTAssertFalse(ubuntuA === alpine)
        XCTAssertEqual(registry.allContexts().count, 2)
    }

    func testRunBootOncePreventsConcurrentDuplicateBoot() {
        let context = InstanceRuntimeContext(instanceName: "ubuntu")
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "msl.tests.registry.boot", attributes: .concurrent)
        let counterLock = NSLock()
        var invokeCount = 0

        for _ in 0..<8 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    try context.runBootOnce {
                        counterLock.lock()
                        invokeCount += 1
                        counterLock.unlock()
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                } catch {
                    XCTFail("boot should not fail: \(error)")
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(invokeCount, 1)
    }
}
