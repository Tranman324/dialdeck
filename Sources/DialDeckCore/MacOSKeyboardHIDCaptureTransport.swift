import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

private struct SelectedKeyboardCollection {
    let device: IOHIDDevice
    let registryEntryID: UInt64
    let elementPlan: KeyboardHIDElementPlan
    let identity: KeyboardHIDChildIdentity
}

private struct KeyboardHIDRuntimeCandidate {
    let device: IOHIDDevice
    let identity: KeyboardHIDChildIdentity
}

private struct KeyboardHIDInputSnapshot {
    let descriptors: [KeyboardHIDElementDescriptor]
    let keyboardApplicationCollectionCount: Int
}

struct MacOSKeyboardHIDCaptureTransport: KeyboardHIDCaptureTransport, Sendable {
    func connectToUniqueTarget() async throws -> any KeyboardHIDCaptureConnection {
        let openingTask = Task.detached(priority: .userInitiated) {
            try Self.openCurrentTarget()
        }
        return try await withTaskCancellationHandler {
            let connection = try await openingTask.value
            guard !Task.isCancelled else {
                await connection.cancel()
                throw CancellationError()
            }
            return connection
        } onCancel: {
            openingTask.cancel()
        }
    }

    private static func openCurrentTarget() throws -> any KeyboardHIDCaptureConnection {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw KeyboardHIDCaptureError.permissionUnavailable
        }

        let firstSelection = try selectCurrentTarget()
        try Task.checkCancellation()
        let currentSelection = try selectCurrentTarget()
        try Task.checkCancellation()
        // The fingerprint omits element cookies; identity also compares the callback plan that binds them.
        guard firstSelection.identity == currentSelection.identity else {
            throw KeyboardHIDCaptureError.targetUnavailable
        }

        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw KeyboardHIDCaptureError.permissionUnavailable
        }

        let connection = MacOSKeyboardHIDCaptureConnection(
            device: currentSelection.device,
            registryEntryID: currentSelection.registryEntryID,
            elementPlan: currentSelection.elementPlan
        )
        try connection.openReadOnly()
        return connection
    }

    /// Enumerates matching keyboard children and selects the unique complete descriptor plan.
    /// This temporary manager has no input callbacks and never seizes the device.
    private static func selectCurrentTarget() throws -> SelectedKeyboardCollection {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw KeyboardHIDCaptureError.permissionUnavailable
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: NSNumber(value: KeyboardHIDTarget.vendorID),
            kIOHIDProductIDKey as String: NSNumber(value: KeyboardHIDTarget.productID),
            kIOHIDTransportKey as String: kIOHIDTransportUSBValue,
            kIOHIDDeviceUsagePageKey as String: NSNumber(value: KeyboardHIDTarget.genericDesktopUsagePage),
            kIOHIDDeviceUsageKey as String: NSNumber(value: KeyboardHIDTarget.keyboardApplicationUsage),
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            throw KeyboardHIDCaptureError.openFailed
        }
        defer { _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) else {
            throw KeyboardHIDCaptureError.targetUnavailable
        }
        let devices = (deviceSet as NSSet).allObjects as! [IOHIDDevice]
        guard !devices.isEmpty else { throw KeyboardHIDCaptureError.targetUnavailable }

        let keyboardDevices = devices.filter { device in
            propertyInteger(device, key: kIOHIDVendorIDKey) == KeyboardHIDTarget.vendorID
                && propertyInteger(device, key: kIOHIDProductIDKey) == KeyboardHIDTarget.productID
                && propertyString(device, key: kIOHIDTransportKey) == kIOHIDTransportUSBValue
                && IOHIDDeviceConformsTo(
                    device,
                    KeyboardHIDTarget.genericDesktopUsagePage,
                    KeyboardHIDTarget.keyboardApplicationUsage
                )
        }
        guard !keyboardDevices.isEmpty else { throw KeyboardHIDCaptureError.targetUnavailable }

        let candidates = keyboardDevices.map { device -> KeyboardHIDRuntimeCandidate in
            let inputSnapshot = try? inputElementSnapshot(for: device)
            let descriptors = inputSnapshot?.descriptors ?? []
            let identity = KeyboardHIDChildIdentity(
                descriptorFingerprint: KeyboardHIDDescriptorFingerprint(descriptors: descriptors),
                usagePairs: usagePairs(for: device),
                keyboardApplicationCollectionCount: inputSnapshot?.keyboardApplicationCollectionCount,
                registryEntryID: try? registryID(for: device),
                elementPlan: try? KeyboardHIDElementPlan(validating: descriptors)
            )
            return KeyboardHIDRuntimeCandidate(device: device, identity: identity)
        }

        let selectedIndex = try KeyboardHIDChildSelection.uniqueEligibleIndex(
            in: candidates.map(\.identity)
        )
        let selected = candidates[selectedIndex]
        guard let registryEntryID = selected.identity.registryEntryID,
              let elementPlan = selected.identity.elementPlan else {
            throw KeyboardHIDCaptureError.interfaceMismatch
        }
        return SelectedKeyboardCollection(
            device: selected.device,
            registryEntryID: registryEntryID,
            elementPlan: elementPlan,
            identity: selected.identity
        )
    }

    private static func inputElementSnapshot(for device: IOHIDDevice) throws -> KeyboardHIDInputSnapshot {
        guard let rawElements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) else {
            throw KeyboardHIDCaptureError.interfaceMismatch
        }
        let elements = rawElements as! [IOHIDElement]
        // A nil element match returns all device elements; count collection nodes directly to include empty ones.
        let keyboardApplicationCollectionCount = Set(
            elements.filter(isKeyboardApplicationCollection).map { UInt32(IOHIDElementGetCookie($0)) }
        ).count
        var descriptors: [KeyboardHIDElementDescriptor] = []

        for element in elements where isInputElement(element) && belongsToUniqueKeyboardCollection(element) {
            guard IOHIDElementGetUsagePage(element) == KeyboardHIDTarget.keyboardUsagePage else { continue }
            let isArray = IOHIDElementIsArray(element)
            let usage = IOHIDElementGetUsage(element)
            let representation: KeyboardHIDElementDescriptor.Representation
            if isArray {
                representation = .array(
                    minimumUsage: propertyInteger(element, key: kIOHIDElementUsageMinKey),
                    maximumUsage: propertyInteger(element, key: kIOHIDElementUsageMaxKey)
                )
            } else {
                representation = .variable(usage: usage)
            }

            descriptors.append(KeyboardHIDElementDescriptor(
                cookie: UInt64(IOHIDElementGetCookie(element)),
                usagePage: IOHIDElementGetUsagePage(element),
                representation: representation,
                reportID: IOHIDElementGetReportID(element),
                reportCount: IOHIDElementGetReportCount(element),
                logicalMinimum: Int64(IOHIDElementGetLogicalMin(element)),
                logicalMaximum: Int64(IOHIDElementGetLogicalMax(element))
            ))
        }
        return KeyboardHIDInputSnapshot(
            descriptors: descriptors,
            keyboardApplicationCollectionCount: keyboardApplicationCollectionCount
        )
    }

    private static func isKeyboardApplicationCollection(_ element: IOHIDElement) -> Bool {
        IOHIDElementGetType(element) == kIOHIDElementTypeCollection
            && IOHIDElementGetCollectionType(element) == kIOHIDElementCollectionTypeApplication
            && IOHIDElementGetUsagePage(element) == KeyboardHIDTarget.genericDesktopUsagePage
            && IOHIDElementGetUsage(element) == KeyboardHIDTarget.keyboardApplicationUsage
    }

    private static func belongsToUniqueKeyboardCollection(_ element: IOHIDElement) -> Bool {
        var current = IOHIDElementGetParent(element)
        var matchingApplications = 0
        while let parent = current {
            if IOHIDElementGetType(parent) == kIOHIDElementTypeCollection,
               IOHIDElementGetCollectionType(parent) == kIOHIDElementCollectionTypeApplication,
               IOHIDElementGetUsagePage(parent) == KeyboardHIDTarget.genericDesktopUsagePage,
               IOHIDElementGetUsage(parent) == KeyboardHIDTarget.keyboardApplicationUsage {
                matchingApplications += 1
            }
            current = IOHIDElementGetParent(parent)
        }
        return matchingApplications == 1
    }

    private static func isInputElement(_ element: IOHIDElement) -> Bool {
        let type = IOHIDElementGetType(element)
        return type == kIOHIDElementTypeInput_Misc
            || type == kIOHIDElementTypeInput_Button
            || type == kIOHIDElementTypeInput_ScanCodes
            || type == kIOHIDElementTypeInput_NULL
    }

    private static func usagePairs(for device: IOHIDDevice) -> [KeyboardHIDUsagePair]? {
        guard let rawPairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? NSArray else {
            return nil
        }
        var pairs: [KeyboardHIDUsagePair] = []
        for value in rawPairs {
            guard let pair = value as? NSDictionary,
                  let page = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.uint32Value,
                  let usage = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.uint32Value else {
                return nil
            }
            pairs.append(KeyboardHIDUsagePair(usagePage: page, usage: usage))
        }
        return pairs.sorted()
    }

    private static func registryID(for device: IOHIDDevice) throws -> UInt64 {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { throw KeyboardHIDCaptureError.interfaceMismatch }
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else {
            throw KeyboardHIDCaptureError.interfaceMismatch
        }
        return identifier
    }

    private static func propertyInteger(_ device: IOHIDDevice, key: String) -> UInt32? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber else { return nil }
        return value.uint32Value
    }

    private static func propertyInteger(_ element: IOHIDElement, key: String) -> UInt32? {
        guard let value = IOHIDElementGetProperty(element, key as CFString) as? NSNumber else { return nil }
        return value.uint32Value
    }

    private static func propertyString(_ device: IOHIDDevice, key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}

private final class MacOSKeyboardHIDCaptureConnection: KeyboardHIDCaptureConnection, @unchecked Sendable {
    private static let eventBufferLimit = 256

    let elementPlan: KeyboardHIDElementPlan
    let events: AsyncStream<KeyboardHIDTransportEvent>

    private let device: IOHIDDevice
    private let registryEntryID: UInt64
    private let continuation: AsyncStream<KeyboardHIDTransportEvent>.Continuation
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var isOpen = false
    private var isClosing = false
    private var cancelHandlerFinished = false
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var permissionMonitor: Task<Void, Never>?

    init(device: IOHIDDevice, registryEntryID: UInt64, elementPlan: KeyboardHIDElementPlan) {
        self.device = device
        self.registryEntryID = registryEntryID
        self.elementPlan = elementPlan
        callbackQueue = DispatchQueue(label: "DialDeck.keyboardHIDCapture")
        let pair = AsyncStream<KeyboardHIDTransportEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferLimit)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    func openReadOnly() throws {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw KeyboardHIDCaptureError.permissionUnavailable
        }
        guard Self.registryEntryID(for: device) == registryEntryID else {
            throw KeyboardHIDCaptureError.targetUnavailable
        }

        let matches: [[String: Any]] = elementPlan.inputsByCookie.map { cookie, input in
            var match: [String: Any] = [
                kIOHIDElementCookieKey as String: NSNumber(value: cookie),
                kIOHIDElementUsagePageKey as String: NSNumber(value: KeyboardHIDTarget.keyboardUsagePage),
            ]
            if case .variable(let usage) = input {
                match[kIOHIDElementUsageKey as String] = NSNumber(value: usage)
            }
            return match
        }
        IOHIDDeviceSetInputValueMatchingMultiple(device, matches as CFArray)
        IOHIDDeviceSetDispatchQueue(device, callbackQueue)

        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            // No callbacks or cancel handler retain this connection's context on failure.
            throw KeyboardHIDCaptureError.openFailed
        }
        isOpen = true

        // Install unretained callback context only once open succeeds, and before activation.
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, Self.inputValueCallback, context)
        IOHIDDeviceRegisterRemovalCallback(device, Self.deviceRemovalCallback, context)
        IOHIDDeviceSetCancelHandler(device) { [weak self] in
            self?.finishCancellation()
        }
        IOHIDDeviceActivate(device)

        permissionMonitor = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
                    self.yield(.permissionLost)
                    return
                }
            }
        }
    }

    func cancel() async {
        permissionMonitor?.cancel()
        permissionMonitor = nil

        enum CancelAction {
            case begin
            case wait
            case complete
        }
        let action = lock.withLock { () -> CancelAction in
            if isClosing {
                return cancelHandlerFinished || !isOpen ? .complete : .wait
            }
            isClosing = true
            return isOpen ? .begin : .complete
        }

        switch action {
        case .begin:
            _ = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDDeviceCancel(device)
            await waitForCancellation()
        case .wait:
            await waitForCancellation()
        case .complete:
            break
        }
        continuation.finish()
    }

    private func waitForCancellation() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if cancelHandlerFinished || !isOpen { return true }
                cancelWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    private func yield(_ event: KeyboardHIDTransportEvent) {
        let mayYield = lock.withLock { !isClosing }
        guard mayYield else { return }
        if case .dropped = continuation.yield(event) {
            // A lost transition could otherwise leave a host key held. End the
            // stream so the session releases its decoder state and reconnects.
            continuation.finish()
        }
    }

    private func finishCancellation() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            cancelHandlerFinished = true
            isOpen = false
            let pending = cancelWaiters
            cancelWaiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    private static let inputValueCallback: IOHIDValueCallback = { context, result, _, value in
        guard let context else { return }
        let connection = Unmanaged<MacOSKeyboardHIDCaptureConnection>
            .fromOpaque(context)
            .takeUnretainedValue()
        guard result == kIOReturnSuccess else {
            connection.yield(.disconnected)
            return
        }
        let element = IOHIDValueGetElement(value)
        let rawValue = KeyboardHIDRawValue(
            cookie: UInt64(IOHIDElementGetCookie(element)),
            usagePage: IOHIDElementGetUsagePage(element),
            elementUsage: IOHIDElementGetUsage(element),
            isArray: IOHIDElementIsArray(element),
            integerValue: Int64(IOHIDValueGetIntegerValue(value))
        )
        connection.yield(.value(rawValue))
    }

    private static let deviceRemovalCallback: IOHIDCallback = { context, _, _ in
        guard let context else { return }
        let connection = Unmanaged<MacOSKeyboardHIDCaptureConnection>
            .fromOpaque(context)
            .takeUnretainedValue()
        connection.yield(.disconnected)
    }

    private static func registryEntryID(for device: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else { return nil }
        return identifier
    }
}
