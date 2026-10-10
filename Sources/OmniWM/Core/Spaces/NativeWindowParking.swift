// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

/// Parks individual windows in an owned native desktop on their assigned display.
/// The journal is written before a move, so an interrupted process can recover it.
@MainActor
final class NativeWindowParking {
    private static let owner = "local.chris.omniwm.native-parking"
    weak var controller: WMController?
    private let bridge = NativeWindowManagementBridge()
    private var journal = Journal()
    private var validatedDesktopIDs: Set<UInt64> = []
    private var requestedSpaces: [WindowToken: Set<UInt64>] = [:]
    private var retryTask: Task<Void, Never>?
    private var deferredFocusTask: Task<Void, Never>?
    private var running = false
    private var restoringAll = false
    private var desktopRecoveryPending = false
    private var lastNormalSpaces: [String: UInt64] = [:]
    private let journalURL: URL
    let enabled: Bool

    init(controller: WMController) {
        self.controller = controller
        enabled = ProcessInfo.processInfo.environment["OMNIWM_NATIVE_WINDOW_PARKING"] == "1"
        journalURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/omniwm-native-parking.json")
    }

    func start() {
        guard enabled, !running else { return }
        running = true
        if let data = try? Data(contentsOf: journalURL),
           let saved = try? JSONDecoder().decode(Journal.self, from: data)
        {
            journal = saved
        }
        let boot = Self.bootSession()
        if journal.bootSession != boot { journal.windows.removeAll() }
        journal.bootSession = boot
        // A restart restores the old session before admitting and parking windows again.
        recoverOrphans()
        retryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.running else { return }
                self.reconcile()
            }
        }
    }

    private static func bootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes
            .withUnsafeMutableBytes { sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            return true
        } catch {
            Log.ax.error("Native parking journal failed: \(error.localizedDescription)")
            return false
        }
    }

    private func owns(_ desktop: ParkingDesktop) -> Bool {
        guard let values = bridge.spaceValues(desktop.id) else { return false }
        return values["OmniWMOwner"] as? String == Self.owner
            && values["uuid"] as? String == desktop.uuid
    }

    private func live(_ record: ParkedWindow) -> Bool {
        if let info = SkyLight.shared.queryWindowInfo(record.windowID) { return info.pid == record.pid }
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return true // An unavailable query must not erase the recovery journal.
        }
        return windows.contains {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == record.windowID
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == record.pid
        }
    }

    func contains(_ token: WindowToken) -> Bool {
        enabled && journal.windows.contains { $0.windowID == token.windowId && $0.pid == token.pid }
    }

    func keepsAlive(_ token: WindowToken) -> Bool {
        guard let record = journal.windows.first(where: { $0.windowID == token.windowId && $0.pid == token.pid }) else {
            return false
        }
        return enabled && live(record)
    }

    func logicalSpaces(for token: WindowToken, actual: [UInt64]) -> [UInt64] {
        guard enabled,
              let record = journal.windows.first(where: { $0.windowID == token.windowId && $0.pid == token.pid }),
              let controller
        else { return actual }
        let displays = SkyLight.shared.managedSpaces()
        let monitor = controller.workspaceManager.workspace(for: token)
            .flatMap { controller.workspaceManager.monitor(for: $0) }
        return restorationSpaces(for: record, monitor: monitor, displays: displays)
    }

    private func displayKey(_ monitor: Monitor) -> String {
        monitor.displayUUID ?? String(monitor.displayId)
    }

    private func displayIdentifier(_ monitor: Monitor, displays: [ManagedDisplaySpaces]) -> String? {
        if let uuid = monitor.displayUUID,
           let display = displays.first(where: { DisplayUUID.canonical($0.displayIdentifier) == uuid })
        {
            return display.displayIdentifier
        }
        if let display = displays.first(where: { $0.displayIdentifier == String(monitor.displayId) }) {
            return display.displayIdentifier
        }
        return monitor.isMain ? displays.first(where: { $0.displayIdentifier == "Main" })?.displayIdentifier : nil
    }

    private func restorationSpaces(
        for record: ParkedWindow, monitor: Monitor?, displays: [ManagedDisplaySpaces]
    ) -> [UInt64] {
        let target = monitor.flatMap { displayIdentifier($0, displays: displays) }
        return Self.restorationSpaces(
            for: record, targetDisplay: target, displays: displays,
            parkingIDs: Set(journal.desktops.map(\.id)), targetIdentity: monitor.map(displayKey)
        )
    }

    private func parkingDesktop(for monitor: Monitor, displays: [ManagedDisplaySpaces]) -> UInt64? {
        guard let identifier = displayIdentifier(monitor, displays: displays),
              let display = displays.first(where: { $0.displayIdentifier == identifier })
        else { return nil }
        let key = displayKey(monitor)
        let presentIDs = Set(displays.flatMap(\.spaceIds))
        var desktop = journal.desktops.first {
            $0.display == key && presentIDs.contains($0.id) && validatedDesktopIDs.contains($0.id)
        }
        if desktop == nil {
            let uuid = UUID().uuidString
            guard let id = bridge.createSpace(values: [
                "uuid": uuid,
                "OmniWMOwner": Self.owner,
                "OmniWMDisplay": key
            ] as NSDictionary) else {
                return nil
            }
            let created = ParkingDesktop(id: id, uuid: uuid, display: key)
            journal.desktops.append(created)
            guard save() else {
                _ = bridge.destroySpace(id)
                journal.desktops.removeAll { $0.id == id }
                return nil
            }
            validatedDesktopIDs.insert(id)
            desktop = created
        }
        guard let desktop else { return nil }
        let actual = SkyLight.shared.managedSpaces().first { $0.spaceIds.contains(desktop.id) }
        guard actual?.displayIdentifier == identifier else {
            _ = bridge.moveSpace(desktop.id, to: identifier, index: UInt32(display.spaceIds.count))
            return nil
        }
        // Never park into the desktop the user is currently looking at.
        guard actual?.currentSpaceId != desktop.id else { return nil }
        return desktop.id
    }

    private func recoveryFrame(for entry: WindowState, monitor: Monitor) -> CGRect? {
        guard let controller,
              var frame = controller.layoutRefreshController.fastFrame(for: entry.token, axRef: entry.axRef)
        else { return nil }
        if let hidden = entry.hiddenState {
            frame.origin.x = monitor.frame.minX + monitor.frame.width * hidden.proportionalPosition.x
            frame.origin.y = monitor.frame.maxY - monitor.frame.height * hidden.proportionalPosition.y - frame.height
        }
        return frame
    }

    @discardableResult
    func park(_ entry: WindowState, monitor: Monitor) -> Bool {
        guard enabled, running, !restoringAll else { return false }
        // Do not fall back to clamped offscreen geometry while macOS is showing
        // our parking desktop. A confirmed recovery schedules the full layout.
        if recoverCurrentParkingDesktops() { return true }
        let displays = SkyLight.shared.managedSpaces()
        guard let parkingID = parkingDesktop(for: monitor, displays: displays) else { return false }
        if let index = journal.windows.firstIndex(where: { $0.windowID == entry.windowId && $0.pid == entry.pid }) {
            if journal.windows[index].parkingSpace != parkingID {
                journal.windows[index].parkingSpace = parkingID
                guard save() else { return false }
            }
        } else {
            let parkingIDs = Set(journal.desktops.map(\.id))
            let original = SkyLight.shared.spacesForWindow(UInt32(entry.windowId)).filter { !parkingIDs.contains($0) }
            guard !original.isEmpty else { return false }
            journal.windows.append(ParkedWindow(
                pid: entry.pid, windowID: UInt32(entry.windowId), originalSpaces: original,
                originalDisplay: displayKey(monitor), parkingSpace: parkingID,
                originalFrame: recoveryFrame(for: entry, monitor: monitor)
            ))
            guard save() else {
                journal.windows.removeLast()
                return false
            }
        }
        let token = entry.token
        controller?.axManager.cancelPendingFrameJobs(
            [(pid: token.pid, windowId: token.windowId)],
            reason: "native-park"
        )
        controller?.axManager.suppressFrameWrites([(pid: token.pid, windowId: token.windowId)])
        let actual = SkyLight.shared.spacesForWindow(UInt32(entry.windowId))
        let target: Set<UInt64> = [parkingID]
        guard Self.needsMove(actual: Set(actual), requested: requestedSpaces[token], target: target) else {
            return true
        }
        guard bridge.moveWindow(UInt32(entry.windowId), to: parkingID) else { return false }
        requestedSpaces[token] = target
        return true
    }

    @discardableResult
    func reveal(_ token: WindowToken, monitor: Monitor? = nil) -> Bool {
        if recoverCurrentParkingDesktops() { return false }
        guard let index = journal.windows.firstIndex(where: { $0.windowID == token.windowId && $0.pid == token.pid })
        else {
            return true
        }
        let record = journal.windows[index]
        guard live(record) else {
            journal.windows.remove(at: index)
            _ = save()
            return true
        }
        let targets = restorationSpaces(for: record, monitor: monitor, displays: SkyLight.shared.managedSpaces())
        guard let first = targets.first else { return false }
        let actual = SkyLight.shared.spacesForWindow(record.windowID)
        let target = Set(targets)
        if Self.needsMove(actual: Set(actual), requested: requestedSpaces[token], target: target) {
            guard bridge.moveWindow(record.windowID, to: first) else { return false }
            if targets.count > 1,
               !bridge.addWindow(record.windowID, to: Array(targets.dropFirst())) { return false }
            requestedSpaces[token] = target
            return false
        }
        if controller?.workspaceManager.entry(for: token) == nil, var frame = record.originalFrame {
            let monitors = controller?.workspaceManager.monitors ?? []
            if !monitors.contains(where: { $0.visibleFrame.intersects(frame) }),
               let monitor = monitors.first(where: \.isMain) ?? monitors.first
            {
                frame.origin = monitor.visibleFrame.origin
            }
            controller?.axManager.applyPositionsViaSkyLight(
                [.init(token: token, frame: frame)], allowInactive: true
            )
        }
        journal.windows.remove(at: index)
        _ = save()
        controller?.axManager.unsuppressFrameWrites([(pid: token.pid, windowId: token.windowId)])
        controller?.axManager.forceApplyNextFrame(for: token.windowId)
        return true
    }

    func parkInactiveWindows() {
        guard enabled, running, !restoringAll, let controller else { return }
        for entry in controller.workspaceManager.allEntries() {
            guard entry.layoutReason != .nativeFullscreen,
                  let monitor = controller.workspaceManager.monitor(for: entry.workspaceId),
                  controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id != entry.workspaceId
            else { continue }
            _ = park(entry, monitor: monitor)
        }
    }

    func revealActiveWindows() {
        guard enabled, let controller else { return }
        for record in journal.windows {
            let token = WindowToken(pid: record.pid, windowId: Int(record.windowID))
            guard let entry = controller.workspaceManager.entry(for: token),
                  let monitor = controller.workspaceManager.monitor(for: entry.workspaceId),
                  controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == entry.workspaceId
            else { continue }
            _ = reveal(token, monitor: monitor)
        }
    }

    func reconcile() {
        guard enabled, running, let controller else { return }
        if recoverCurrentParkingDesktops() { return }
        var revealed = false
        for record in journal.windows {
            let token = WindowToken(pid: record.pid, windowId: Int(record.windowID))
            guard let entry = controller.workspaceManager.entry(for: token) else {
                revealed = reveal(token) || revealed
                continue
            }
            guard let monitor = controller.workspaceManager.monitor(for: entry.workspaceId) else { continue }
            if restoringAll || controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == entry
                .workspaceId
            {
                revealed = reveal(token, monitor: monitor) || revealed
            } else {
                _ = park(entry, monitor: monitor)
            }
        }
        cleanupDesktops()
        if revealed { controller.layoutRefreshController.requestRelayout(reason: .gapsChanged) }
    }

    @discardableResult
    private func recoverCurrentParkingDesktops() -> Bool {
        guard enabled, running, !restoringAll else { return false }
        let recovery = NativeParkingDesktopRecovery { [bridge] display, target, parking in
            bridge.returnToDesktop(display: display, target: target, parking: parking)
        }
        let displays = SkyLight.shared.managedSpaces()
        for display in displays where !validatedDesktopIDs.contains(display.currentSpaceId)
            && !display.fullscreenSpaceIds.contains(display.currentSpaceId)
        {
            lastNormalSpaces[display.displayIdentifier] = display.currentSpaceId
        }
        if recovery.recover(
            displays: displays, parkingIDs: validatedDesktopIDs, normalSpaces: lastNormalSpaces
        ) {
            desktopRecoveryPending = true
            return true
        }
        if desktopRecoveryPending {
            desktopRecoveryPending = false
            controller?.layoutRefreshController.requestRelayout(reason: .gapsChanged)
        }
        return false
    }
}

// Native desktop recovery and shutdown share the same journal and ownership checks.
@MainActor
extension NativeWindowParking {
    private func cleanupDesktops() {
        let connected = Set((controller?.workspaceManager.monitors ?? []).map(displayKey))
        let occupied = Set(journal.windows.map(\.parkingSpace))
        for desktop in journal.desktops where !occupied.contains(desktop.id)
            && (restoringAll || !connected.contains(desktop.display))
        {
            guard owns(desktop),
                  let display = SkyLight.shared.managedSpaces().first(where: { $0.spaceIds.contains(desktop.id) }),
                  display.currentSpaceId != desktop.id
            else { continue }
            if case let .authoritative(inventory) = SkyLight.shared.nativeSpaceWindowInventory(spaceIds: [desktop.id]),
               inventory[desktop.id]?.isEmpty == true
            {
                _ = bridge.destroySpace(desktop.id)
                journal.desktops.removeAll { $0.id == desktop.id }
                _ = save()
            }
        }
    }

    private func recoverOrphans() {
        let managed = SkyLight.shared.managedSpaces()
        for display in managed {
            for id in display.spaceIds where !journal.desktops.contains(where: { $0.id == id }) {
                guard let values = bridge.spaceValues(id), values["OmniWMOwner"] as? String == Self.owner,
                      let uuid = values["uuid"] as? String
                else { continue }
                journal.desktops.append(ParkingDesktop(
                    id: id, uuid: uuid, display: values["OmniWMDisplay"] as? String ?? display.displayIdentifier
                ))
            }
        }
        let presentIDs = Set(managed.flatMap(\.spaceIds))
        journal.desktops.removeAll { desktop in
            guard presentIDs.contains(desktop.id) else { return true }
            guard let values = bridge.spaceValues(desktop.id) else { return false }
            return values["OmniWMOwner"] as? String != Self.owner || values["uuid"] as? String != desktop.uuid
        }
        validatedDesktopIDs = Set(journal.desktops.filter { owns($0) }.map(\.id))
        let ownedIDs = Set(journal.desktops.map(\.id))
        journal.windows.removeAll { !ownedIDs.contains($0.parkingSpace) || !live($0) }
        // Include windows created on a parking desktop while OmniWM was stopped.
        for desktop in journal.desktops {
            if case let .authoritative(inventory) = SkyLight.shared.nativeSpaceWindowInventory(spaceIds: [desktop.id]) {
                for info in inventory[desktop.id] ?? []
                    where !journal.windows.contains(where: { $0.windowID == info.id })
                {
                    let fallback = managed.first { $0.spaceIds.contains(desktop.id) }?.spaceIds
                        .filter { !ownedIDs.contains($0) } ?? []
                    journal.windows.append(ParkedWindow(
                        pid: info.pid, windowID: info.id, originalSpaces: Array(fallback.prefix(1)),
                        originalDisplay: desktop.display, parkingSpace: desktop.id
                    ))
                }
            }
        }
        _ = save()
        for record in journal.windows {
            _ = reveal(WindowToken(pid: record.pid, windowId: Int(record.windowID)))
        }
    }

    func stop() {
        guard enabled else { return }
        cancelDeferredFocus()
        restoringAll = true
        for record in journal.windows {
            _ = reveal(WindowToken(pid: record.pid, windowId: Int(record.windowID)))
        }
        // Keep recovery retries alive until asynchronous moves are confirmed.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0 ..< 20 {
                self.reconcile()
                if self.journal.windows.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self.cleanupDesktops()
            self.running = false
            self.restoringAll = false
            self.retryTask?.cancel()
            self.retryTask = nil
        }
    }
}

@MainActor
extension NativeWindowParking {
    func cancelDeferredFocus() {
        deferredFocusTask?.cancel()
        deferredFocusTask = nil
    }

    func deferFocus(_ token: WindowToken, completion: @escaping @MainActor () -> Void) {
        cancelDeferredFocus()
        deferredFocusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0 ..< 40 {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                guard self.running, let controller = self.controller,
                      let entry = controller.workspaceManager.entry(for: token),
                      let monitor = controller.workspaceManager.monitor(for: entry.workspaceId),
                      controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == entry.workspaceId
                else { return }
                if self.reveal(token, monitor: monitor) {
                    completion()
                    return
                }
            }
        }
    }
}
