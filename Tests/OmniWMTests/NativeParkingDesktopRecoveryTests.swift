// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class NativeParkingDesktopRecoveryTests: XCTestCase {
    func testLastWindowQuitReturnsFromParkingDesktopWithoutMovingOtherWorkspaces() {
        // Kitty's last window disappears from desktop 1. macOS activates the
        // parked Zen window on desktop 9, although OmniWM still selects workspace 1.
        var current: UInt64 = 9
        var visible: Set<UInt64> = [9]
        let zenMembership: Set<UInt64> = [9]
        let zenWorkspace = 2
        var operations: [(String, UInt64, UInt64)] = []
        let recovery = NativeParkingDesktopRecovery { display, target, parking in
            operations.append((display, target, parking))
            visible.insert(target)
            current = target
            visible.remove(parking)
            return true
        }
        XCTAssertTrue(recovery.recover(displays: [display("laptop", current: current)], parkingIDs: [9]))
        XCTAssertEqual(current, 1)
        XCTAssertEqual(visible, [1])
        XCTAssertEqual(zenMembership, [9])
        XCTAssertEqual(zenWorkspace, 2)
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations.first?.0, "laptop")
        XCTAssertEqual(operations.first?.1, 1)
        XCTAssertEqual(operations.first?.2, 9)
        XCTAssertFalse(recovery.recover(displays: [display("laptop", current: current)], parkingIDs: [9]))
        XCTAssertEqual(operations.count, 1)
    }

    func testOnlyAffectedMonitorReturnsFromItsOwnedParkingDesktop() {
        var operations: [String] = []
        let recovery = NativeParkingDesktopRecovery { name, target, parking in
            operations.append("\(name):\(parking)->\(target)")
            return true
        }
        XCTAssertTrue(recovery.recover(displays: [
            display("laptop", current: 1),
            .init(displayIdentifier: "external", spaceIds: [2, 10], currentSpaceId: 10, fullscreenSpaceIds: [])
        ], parkingIDs: [9, 10]))
        XCTAssertEqual(operations, ["external:10->2"])
    }

    func testReturnsToPreviouslySelectedNormalDesktopOnThatDisplay() {
        var targetSpace: UInt64?
        let recovery = NativeParkingDesktopRecovery { _, target, _ in
            targetSpace = target
            return true
        }
        XCTAssertTrue(recovery.recover(
            displays: [display("laptop", current: 9)], parkingIDs: [9], normalSpaces: ["laptop": 3]
        ))
        XCTAssertEqual(targetSpace, 3)
    }

    func testOrdinaryNativeDesktopAndFullscreenAreNotHijacked() {
        let recovery = NativeParkingDesktopRecovery { _, _, _ in
            XCTFail("Do not redirect a user's ordinary desktop or fullscreen space")
            return true
        }
        XCTAssertFalse(recovery.recover(displays: [display("laptop", current: 3)], parkingIDs: [9]))
        XCTAssertFalse(recovery.recover(displays: [
            .init(displayIdentifier: "laptop", spaceIds: [1, 7, 9], currentSpaceId: 7, fullscreenSpaceIds: [7])
        ], parkingIDs: [9]))
    }

    func testNoNormalDesktopDefersRecoveryAndNeverSelectsFullscreen() {
        let recovery = NativeParkingDesktopRecovery { _, _, _ in
            XCTFail("No normal desktop exists")
            return true
        }
        XCTAssertFalse(recovery.recover(displays: [
            .init(displayIdentifier: "laptop", spaceIds: [7, 9], currentSpaceId: 9, fullscreenSpaceIds: [7])
        ], parkingIDs: [9]))
    }

    private func display(_ name: String, current: UInt64) -> ManagedDisplaySpaces {
        .init(displayIdentifier: name, spaceIds: [1, 3, 9], currentSpaceId: current, fullscreenSpaceIds: [])
    }
}
