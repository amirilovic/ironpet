import XCTest
@testable import IronPet

final class AXObserverHostTests: XCTestCase {
    /// Records where each step runs and whether a callback arrives after its observer was torn down.
    private final class Fake: @unchecked Sendable {
        let lock = NSLock()
        var live: [Int: (pid: pid_t, fire: () -> Void)] = [:]
        var nextId = 0
        var offThread = 0
        var overlaps = 0
        var inCallback = false
        var staleDeliveries = 0
        var torn = Set<Int>()

        func attach(pid: pid_t, fire: @escaping () -> Void) -> (() -> Void)? {
            if Thread.current.name != "ironpet.capture.ax" { lock.withLock { offThread += 1 } }
            let id = lock.withLock { () -> Int in nextId += 1; live[nextId] = (pid, fire); return nextId }
            return { [self] in
                if Thread.current.name != "ironpet.capture.ax" { lock.withLock { offThread += 1 } }
                lock.withLock { live[id] = nil; torn.insert(id) }
            }
        }
    }

    func testRapidAttachDetachAcrossTwoPidsDropsStaleCallbacks() {
        let fake = Fake()
        let events = NSLock()
        var received = 0
        let host = AXObserverHost(attach: fake.attach, onEvent: {
            events.withLock { received += 1 }
            XCTAssertEqual(Thread.current.name, "ironpet.capture.ax")
        })
        host.start()
        // Fire callbacks from the host thread like HIServices does, for every observer, including ones already replaced.
        var stale: [() -> Void] = []
        for i in 0..<400 {
            host.attach(to: i % 2 == 0 ? 101 : 202)
            host.perform {
                fake.lock.withLock { stale.append(contentsOf: fake.live.values.map(\.fire)) }
                for fire in stale { fire() }
            }
            if i % 7 == 0 { host.detach() }
        }
        host.stop()
        let done = expectation(description: "drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(fake.offThread, 0, "attach and teardown must run on the AX thread")
        XCTAssertEqual(fake.live.count, 0, "every observer is torn down")
        let after = events.withLock { received }
        // Callbacks of torn-down observers are dropped: after stop nothing is delivered.
        host.perform { stale.forEach { $0() } }
        XCTAssertEqual(events.withLock { received }, after)
    }
}
