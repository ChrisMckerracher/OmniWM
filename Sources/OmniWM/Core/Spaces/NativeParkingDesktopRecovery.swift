// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

/// An automatic app activation can select a desktop reserved for parked windows.
@MainActor
struct NativeParkingDesktopRecovery {
    var returnToDesktop: (String, UInt64, UInt64) -> Bool

    @discardableResult
    func recover(
        displays: [ManagedDisplaySpaces], parkingIDs: Set<UInt64>, normalSpaces: [String: UInt64] = [:]
    ) -> Bool {
        var requested = false
        for display in displays where parkingIDs.contains(display.currentSpaceId) {
            let normal = display.spaceIds.filter {
                !parkingIDs.contains($0) && !display.fullscreenSpaceIds.contains($0)
            }
            let remembered = normalSpaces[display.displayIdentifier].flatMap { normal.contains($0) ? $0 : nil }
            guard let target = remembered ?? normal.first else { continue }
            requested = returnToDesktop(display.displayIdentifier, target, display.currentSpaceId) || requested
        }
        return requested
    }
}
