// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
extension NativeWindowParking {
    static func shouldPreserveDestroyedWindow(
        evidence: AXEventHandler.WindowDestroyEvidence, stillLive: Bool
    ) -> Bool {
        evidence == .transientLifecycle && stillLive
    }

    struct ParkingDesktop: Codable {
        var id: UInt64
        var uuid: String
        var display: String
    }

    struct ParkedWindow: Codable {
        var pid: Int32
        var windowID: UInt32
        var originalSpaces: [UInt64]
        var originalDisplay: String
        var parkingSpace: UInt64
        var originalFrame: CGRect?
    }

    struct Journal: Codable {
        var bootSession: String?
        var desktops: [ParkingDesktop] = []
        var windows: [ParkedWindow] = []
    }

    /// The observed membership can lag an opposite move already queued in macOS.
    static func needsMove(actual: Set<UInt64>, requested: Set<UInt64>?, target: Set<UInt64>) -> Bool {
        actual != target || (requested != nil && requested != target)
    }

    static func restorationSpaces(
        for record: ParkedWindow, targetDisplay: String?, displays: [ManagedDisplaySpaces],
        parkingIDs: Set<UInt64>, targetIdentity: String? = nil
    ) -> [UInt64] {
        let target = targetDisplay.flatMap { identifier in displays.first { $0.displayIdentifier == identifier } }
        let available = Set(displays.flatMap(\.spaceIds)).subtracting(parkingIDs)
            .subtracting(displays.flatMap { $0.fullscreenSpaceIds })
        let original = record.originalSpaces.filter { available.contains($0) }
        if target == nil || (targetIdentity ?? target?.displayIdentifier) == record.originalDisplay, !original.isEmpty {
            return original
        }
        if let target {
            if available.contains(target.currentSpaceId) { return [target.currentSpaceId] }
            if let normal = target.spaceIds.first(where: { available.contains($0) }) { return [normal] }
        }
        return displays.compactMap { display in
            available.contains(display.currentSpaceId) ? display.currentSpaceId : nil
        }.first.map { [$0] } ?? available.min().map { [$0] } ?? []
    }
}
