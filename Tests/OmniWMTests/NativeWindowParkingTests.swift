// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NativeWindowParkingTests: XCTestCase {
    private func display(
        _ name: String,
        spaces: [UInt64],
        current: UInt64,
        fullscreen: Set<UInt64> = []
    ) -> ManagedDisplaySpaces {
        .init(displayIdentifier: name, spaceIds: spaces, currentSpaceId: current, fullscreenSpaceIds: fullscreen)
    }

    private func record(_ spaces: [UInt64] = [1], display: String = "laptop") -> NativeWindowParking.ParkedWindow {
        .init(pid: 123, windowID: 456, originalSpaces: spaces, originalDisplay: display, parkingSpace: 9)
    }

    func testAddingMonitorKeepsOriginalDesktopMembership() {
        let targets = NativeWindowParking.restorationSpaces(
            for: record(), targetDisplay: "laptop",
            displays: [display("laptop", spaces: [1, 9], current: 1), display("external", spaces: [2, 10], current: 2)],
            parkingIDs: [9, 10]
        )
        XCTAssertEqual(targets, [1])
    }

    func testMainDisplayAliasChangePreservesPhysicalMonitorMembership() {
        XCTAssertEqual(NativeWindowParking.restorationSpaces(
            for: record([1, 3], display: "physical-laptop-uuid"), targetDisplay: "Main",
            displays: [display("Main", spaces: [1, 3, 9], current: 1)], parkingIDs: [9],
            targetIdentity: "physical-laptop-uuid"
        ), [1, 3])
    }

    func testWorkspaceMovedToOtherMonitorUsesThatMonitorsDesktop() {
        XCTAssertEqual(NativeWindowParking.restorationSpaces(
            for: record(), targetDisplay: "external",
            displays: [display("laptop", spaces: [1, 9], current: 1), display("external", spaces: [2, 10], current: 2)],
            parkingIDs: [9, 10]
        ), [2])
    }

    func testDisconnectedMonitorRestoresToRemainingMonitor() {
        XCTAssertEqual(NativeWindowParking.restorationSpaces(
            for: record([2], display: "external"), targetDisplay: "laptop",
            displays: [display("laptop", spaces: [1, 9, 10], current: 1)], parkingIDs: [9, 10]
        ), [1])
    }

    func testNeverRestoresIntoParkingDesktopOrFullscreen() {
        XCTAssertEqual(NativeWindowParking.restorationSpaces(
            for: record([7]), targetDisplay: "laptop",
            displays: [display("laptop", spaces: [7, 9, 1], current: 9, fullscreen: [7])], parkingIDs: [9]
        ), [1])
    }

    func testNoNormalDesktopDefersRestoration() {
        XCTAssertEqual(NativeWindowParking.restorationSpaces(
            for: record(), targetDisplay: "laptop",
            displays: [display("laptop", spaces: [9], current: 9)], parkingIDs: [9]
        ), [])
    }

    func testRestoresMultipleOriginalMemberships() {
        XCTAssertEqual(NativeWindowParking.restorationSpaces(
            for: record([1, 3]), targetDisplay: "laptop",
            displays: [display("laptop", spaces: [1, 3, 9], current: 1)], parkingIDs: [9]
        ), [1, 3])
    }

    func testJournalPreservesRecoveryGeometryAndOwnership() throws {
        let original = NativeWindowParking.Journal(
            desktops: [.init(id: 9, uuid: "ownership-token", display: "external")],
            windows: [.init(
                pid: 123,
                windowID: 456,
                originalSpaces: [2],
                originalDisplay: "external",
                parkingSpace: 9,
                originalFrame: CGRect(x: 1470, y: 10, width: 900, height: 700)
            )]
        )
        let restored = try JSONDecoder().decode(NativeWindowParking.Journal.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.desktops.first?.uuid, "ownership-token")
        XCTAssertEqual(restored.windows.first?.originalFrame, original.windows.first?.originalFrame)
        XCTAssertEqual(restored.windows.first?.originalSpaces, [2])
    }
}
