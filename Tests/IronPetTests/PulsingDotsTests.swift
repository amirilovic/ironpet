import AppKit
import XCTest
@testable import IronPet

@MainActor
final class PulsingDotsTests: XCTestCase {
    private func host(_ view: PulsingDots.DotsView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        view.frame = NSRect(x: 0, y: 0, width: 30, height: 6)
        window.contentView?.addSubview(view)
        return window
    }

    func testAttachingToAWindowInstallsStaggeredAnimations() throws {
        let view = PulsingDots.DotsView()
        XCTAssertNil(view.dotAnimation(0))
        let window = host(view)
        withExtendedLifetime(window) {}
        var begins: [CFTimeInterval] = []
        for i in 0..<3 {
            let anim = try XCTUnwrap(view.dotAnimation(i) as? CAKeyframeAnimation)
            XCTAssertEqual(anim.duration, PulsingDots.DotsView.cycle)
            XCTAssertEqual(anim.repeatCount, .infinity)
            XCTAssertFalse(anim.isRemovedOnCompletion)
            begins.append(anim.beginTime)
        }
        let step = PulsingDots.DotsView.cycle / 3
        XCTAssertEqual(begins[1] - begins[0], step, accuracy: 0.001)
        XCTAssertEqual(begins[2] - begins[1], step, accuracy: 0.001)
    }

    func testReattachingReinstallsWithoutDuplicating() throws {
        let view = PulsingDots.DotsView()
        let window = host(view)
        view.removeFromSuperview()
        XCTAssertNil(view.dotAnimation(0))
        window.contentView?.addSubview(view)
        let layer = try XCTUnwrap(view.layer?.sublayers?.first)
        XCTAssertEqual(layer.animationKeys(), [PulsingDots.DotsView.animationKey])
        XCTAssertNotNil(view.dotAnimation(2))
    }

    func testReduceMotionUsesASlowerCycle() {
        let normal = PulsingDots.DotsView.animation(index: 0, layerTime: 0, reduceMotion: false)
        let reduced = PulsingDots.DotsView.animation(index: 0, layerTime: 0, reduceMotion: true)
        XCTAssertGreaterThan(reduced.duration, normal.duration * 1.5)
        let view = PulsingDots.DotsView()
        view.reduceMotionOverride = true
        let window = host(view)
        withExtendedLifetime(window) {}
        XCTAssertEqual(view.dotAnimation(0)?.duration, PulsingDots.DotsView.reducedMotionCycle)
    }
}
