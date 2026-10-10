// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ObjectiveC

/// Apple's per-process window-management bridge. No Dock injection is involved.
@MainActor
struct NativeWindowManagementBridge {
    private static let message = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")
    private typealias Send = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?

    private func allocate(_ name: String, initializer: String) -> NSObject? {
        guard let cls = NSClassFromString(name),
              class_getInstanceMethod(cls, NSSelectorFromString(initializer)) != nil,
              let message = Self.message
        else { return nil }
        return unsafeBitCast(message, to: Send.self)(cls, NSSelectorFromString("alloc"))?
            .takeRetainedValue() as? NSObject
    }

    private func result(_ operation: NSObject) -> NSObject? {
        let selector = NSSelectorFromString("performWithWMBridgeDelegate")
        guard operation.responds(to: selector), let message = Self.message else { return nil }
        return unsafeBitCast(message, to: Send.self)(operation, selector)?.takeUnretainedValue() as? NSObject
    }

    private func submit(_ operation: NSObject) -> Bool {
        let selector = NSSelectorFromString("performWithWMBridgeDelegate")
        guard operation.responds(to: selector), let message = Self.message else { return false }
        typealias Invoke = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(message, to: Invoke.self)(operation, selector)
        return true
    }

    private func initializeSpace(_ name: String, spaceID: UInt64) -> NSObject? {
        let selector = NSSelectorFromString("initWithSpaceID:")
        guard let allocated = allocate(name, initializer: "initWithSpaceID:"), let message = Self.message else {
            return nil
        }
        typealias Initialize = @convention(c) (AnyObject, Selector, UInt64) -> Unmanaged<AnyObject>?
        return unsafeBitCast(message, to: Initialize.self)(allocated, selector, spaceID)?
            .takeUnretainedValue() as? NSObject
    }

    func createSpace(values: NSDictionary) -> UInt64? {
        let initializer = "initWithOptions:values:"
        guard let allocated = allocate("SLSBridgedSpaceCreateOperation", initializer: initializer),
              let message = Self.message
        else { return nil }
        typealias Initialize = @convention(c) (AnyObject, Selector, UInt32, NSDictionary) -> Unmanaged<AnyObject>?
        guard let operation = unsafeBitCast(message, to: Initialize.self)(
            allocated, NSSelectorFromString(initializer), 0, values
        )?.takeUnretainedValue() as? NSObject,
            let result = result(operation), result.responds(to: NSSelectorFromString("spaceID"))
        else { return nil }
        typealias SpaceID = @convention(c) (AnyObject, Selector) -> UInt64
        let spaceID = unsafeBitCast(message, to: SpaceID.self)(result, NSSelectorFromString("spaceID"))
        return spaceID == 0 ? nil : spaceID
    }

    func spaceValues(_ spaceID: UInt64) -> NSDictionary? {
        guard let operation = initializeSpace("SLSBridgedSpaceCopyValuesOperation", spaceID: spaceID),
              let result = result(operation), result.responds(to: NSSelectorFromString("propertyListDictionary")),
              let message = Self.message
        else { return nil }
        return unsafeBitCast(message, to: Send.self)(result, NSSelectorFromString("propertyListDictionary"))?
            .takeUnretainedValue() as? NSDictionary
    }

    func moveWindow(_ windowID: UInt32, to spaceID: UInt64) -> Bool {
        let initializer = "initWithWindows:spaceID:"
        guard let allocated = allocate("SLSBridgedMoveWindowsToManagedSpaceOperation", initializer: initializer),
              let message = Self.message
        else { return false }
        typealias Initialize = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> Unmanaged<AnyObject>?
        guard let operation = unsafeBitCast(message, to: Initialize.self)(
            allocated, NSSelectorFromString(initializer), [NSNumber(value: windowID)] as NSArray, spaceID
        )?.takeUnretainedValue() as? NSObject else { return false }
        return submit(operation)
    }

    func addWindow(_ windowID: UInt32, to spaces: [UInt64]) -> Bool {
        let initializer = "initWithWindows:spaces:"
        guard let allocated = allocate("SLSBridgedAddWindowsToSpacesOperation", initializer: initializer),
              let message = Self.message
        else { return false }
        typealias Initialize = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> Unmanaged<AnyObject>?
        guard let operation = unsafeBitCast(message, to: Initialize.self)(
            allocated, NSSelectorFromString(initializer), [NSNumber(value: windowID)] as NSArray,
            spaces.map { NSNumber(value: $0) } as NSArray
        )?.takeUnretainedValue() as? NSObject else { return false }
        return submit(operation)
    }

    func moveSpace(_ spaceID: UInt64, to display: String, index: UInt32) -> Bool {
        let initializer = "initWithSpaceID:displayIdentifier:index:"
        guard let allocated = allocate("SLSBridgedMoveManagedSpaceToDisplayIndexOperation", initializer: initializer),
              let message = Self.message
        else { return false }
        typealias Initialize = @convention(c) (AnyObject, Selector, UInt64, NSString, UInt32)
            -> Unmanaged<AnyObject>?
        guard let operation = unsafeBitCast(message, to: Initialize.self)(
            allocated, NSSelectorFromString(initializer), spaceID, display as NSString, index
        )?.takeUnretainedValue() as? NSObject else { return false }
        return submit(operation)
    }

    func destroySpace(_ spaceID: UInt64) -> Bool {
        guard let operation = initializeSpace("SLSBridgedSpaceDestroyOperation", spaceID: spaceID) else {
            return false
        }
        return submit(operation)
    }

    /// Selecting a desktop alone does not change which desktops are visible.
    func returnToDesktop(display: String, target: UInt64, parking: UInt64) -> Bool {
        let initializer = "initWithDisplayIdentifier:spaceID:"
        guard let allocated = allocate("SLSBridgedManagedDisplaySetCurrentSpaceOperation", initializer: initializer),
              let show = initializeSpaces("SLSBridgedShowSpacesOperation", spaces: [target]),
              let hide = initializeSpaces("SLSBridgedHideSpacesOperation", spaces: [parking]),
              let message = Self.message
        else { return false }
        typealias Initialize = @convention(c) (AnyObject, Selector, NSString, UInt64) -> Unmanaged<AnyObject>?
        guard let select = unsafeBitCast(message, to: Initialize.self)(
            allocated, NSSelectorFromString(initializer), display as NSString, target
        )?.takeUnretainedValue() as? NSObject else { return false }
        return submit(show) && submit(select) && submit(hide)
    }

    private func initializeSpaces(_ name: String, spaces: [UInt64]) -> NSObject? {
        let initializer = "initWithSpaces:"
        guard let allocated = allocate(name, initializer: initializer), let message = Self.message else {
            return nil
        }
        typealias Initialize = @convention(c) (AnyObject, Selector, NSArray) -> Unmanaged<AnyObject>?
        return unsafeBitCast(message, to: Initialize.self)(
            allocated, NSSelectorFromString(initializer), spaces.map { NSNumber(value: $0) } as NSArray
        )?.takeUnretainedValue() as? NSObject
    }
}
