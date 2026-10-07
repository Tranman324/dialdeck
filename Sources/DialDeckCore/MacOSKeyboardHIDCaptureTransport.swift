import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

private struct SelectedKeyboardCollection {
    let device: IOHIDDevice
    let registryEntryID: UInt64
    let reportDescriptor: Data
}

enum KeyboardHIDCaptureDiagnostic: Sendable {
    case selectedChild(registryEntryID: UInt64)
    case managerClosed(selectedRegistryEntryID: UInt64?, result: Int32)
    case deviceRemoved(registryEntryID: UInt64)
    case deviceCancelIssued(registryEntryID: UInt64)
    case deviceClosed(registryEntryID: UInt64, result: Int32)
    case deviceCloseSkippedRemoved(registryEntryID: UInt64)
}

struct MacOSKeyboardHIDCaptureTransport: KeyboardHIDCaptureTransport, Sendable {
    private let diagnosticHandler: (@Sendable (KeyboardHIDCaptureDiagnostic) -> Void)?

    init(
        diagnosticHandler: (@Sendable (KeyboardHIDCaptureDiagnostic) -> Void)? = nil
    ) {
        self.diagnosticHandler = diagnosticHandler
    }

    func connectToUniqueTarget(
        focusEpochClock: FocusEpochClock
    ) async throws -> any KeyboardHIDCaptureConnection {
        let openingTask = Task.detached(priority: .userInitiated) {
            try Self.openCurrentTarget(
                diagnosticHandler: diagnosticHandler,
                focusEpochClock: focusEpochClock
            )
        }
        return try await withTaskCancellationHandler {
            let connection = try await openingTask.value
            guard !Task.isCancelled else {
                if let closeError = await connection.cancel() { throw closeError }
                throw CancellationError()
            }
            return connection
        } onCancel: {
            openingTask.cancel()
        }
    }

    private static func openCurrentTarget(
        diagnosticHandler: (@Sendable (KeyboardHIDCaptureDiagnostic) -> Void)?,
        focusEpochClock: FocusEpochClock
    ) throws -> any KeyboardHIDCaptureConnection {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw KeyboardHIDCaptureError.permissionUnavailable
        }

        let firstSelection = try selectCurrentTarget(diagnosticHandler: diagnosticHandler)
        try Task.checkCancellation()
        let currentSelection = try selectCurrentTarget(diagnosticHandler: diagnosticHandler)
        try Task.checkCancellation()
        guard firstSelection.registryEntryID == currentSelection.registryEntryID,
              firstSelection.reportDescriptor == currentSelection.reportDescriptor else {
            throw KeyboardHIDCaptureError.targetUnavailable
        }

        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw KeyboardHIDCaptureError.permissionUnavailable
        }

        let connection = MacOSKeyboardHIDCaptureConnection(
            device: currentSelection.device,
            registryEntryID: currentSelection.registryEntryID,
            reportDescriptor: currentSelection.reportDescriptor,
            elementPlan: KeyboardHIDElementPlan.observedArrayControlPlan,
            focusEpochClock: focusEpochClock,
            diagnosticHandler: diagnosticHandler
        )
        try connection.openReadOnly()
        return connection
    }

    /// Selects only the target child whose complete ReportDescriptor matches
    /// the captured keyboard-array descriptor. The manager is non-seizing and
    /// is closed before the selected device is opened directly.
    private static func selectCurrentTarget(
        diagnosticHandler: (@Sendable (KeyboardHIDCaptureDiagnostic) -> Void)?
    ) throws -> SelectedKeyboardCollection {
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
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw KeyboardHIDCaptureError.openFailed
        }

        let selected: SelectedKeyboardCollection
        do {
            selected = try selectMatchingKeyboardChild(from: manager)
        } catch {
            let closeResult = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            diagnosticHandler?(.managerClosed(selectedRegistryEntryID: nil, result: Int32(closeResult)))
            guard closeResult == kIOReturnSuccess else {
                throw KeyboardHIDCaptureError.managerCloseFailed(Int32(closeResult))
            }
            throw error
        }

        diagnosticHandler?(.selectedChild(registryEntryID: selected.registryEntryID))
        let closeResult = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        diagnosticHandler?(.managerClosed(
            selectedRegistryEntryID: selected.registryEntryID,
            result: Int32(closeResult)
        ))
        guard closeResult == kIOReturnSuccess else {
            throw KeyboardHIDCaptureError.managerCloseFailed(Int32(closeResult))
        }
        return selected
    }

    private static func selectMatchingKeyboardChild(from manager: IOHIDManager) throws -> SelectedKeyboardCollection {
        guard let deviceSet = IOHIDManagerCopyDevices(manager) else {
            throw KeyboardHIDCaptureError.targetUnavailable
        }
        let devices = (deviceSet as NSSet).allObjects as! [IOHIDDevice]
        let keyboardDevices = devices.filter(isTargetKeyboard)
        guard !keyboardDevices.isEmpty else {
            throw KeyboardHIDCaptureError.targetUnavailable
        }

        let descriptors = keyboardDevices.map(reportDescriptor(for:))
        let selectedIndex = try KeyboardHIDRawReportInterfaceSelection.uniqueMatchingIndex(
            in: descriptors
        )
        let device = keyboardDevices[selectedIndex]
        guard let descriptor = descriptors[selectedIndex] else {
            throw KeyboardHIDCaptureError.interfaceMismatch
        }
        let selection = SelectedKeyboardCollection(
            device: device,
            registryEntryID: try registryID(for: device),
            reportDescriptor: descriptor
        )
        return selection
    }

    private static func isTargetKeyboard(_ device: IOHIDDevice) -> Bool {
        propertyInteger(device, key: kIOHIDVendorIDKey) == KeyboardHIDTarget.vendorID
            && propertyInteger(device, key: kIOHIDProductIDKey) == KeyboardHIDTarget.productID
            && propertyString(device, key: kIOHIDTransportKey) == kIOHIDTransportUSBValue
            && IOHIDDeviceConformsTo(
                device,
                KeyboardHIDTarget.genericDesktopUsagePage,
                KeyboardHIDTarget.keyboardApplicationUsage
            )
    }

    private static func reportDescriptor(for device: IOHIDDevice) -> Data? {
        IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
    }

    private static func registryID(for device: IOHIDDevice) throws -> UInt64 {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else {
            throw KeyboardHIDCaptureError.interfaceMismatch
        }
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS,
              identifier != 0 else {
            throw KeyboardHIDCaptureError.interfaceMismatch
        }
        return identifier
    }

    private static func propertyInteger(_ device: IOHIDDevice, key: String) -> UInt32? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.uint32Value
    }

    private static func propertyString(_ device: IOHIDDevice, key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}

private final class MacOSKeyboardHIDCaptureConnection: KeyboardHIDCaptureConnection, @unchecked Sendable {
    private static let eventBufferLimit = 256
    private static let inputReportBufferCapacity = 256

    let elementPlan: KeyboardHIDElementPlan
    let events: AsyncStream<KeyboardHIDTransportEvent>

    private let device: IOHIDDevice
    private let registryEntryID: UInt64
    private let reportDescriptor: Data
    private let focusEpochClock: FocusEpochClock
    private let reportBuffer: UnsafeMutablePointer<UInt8>
    private let continuation: AsyncStream<KeyboardHIDTransportEvent>.Continuation
    private let callbackQueue: DispatchQueue
    private let diagnosticHandler: (@Sendable (KeyboardHIDCaptureDiagnostic) -> Void)?
    private let lock = NSLock()
    private var reportDecoder = KeyboardHIDRawReportDecoder()
    private var hasOpenHandle = false
    private var deviceWasRemoved = false
    private var isClosing = false
    private var cancellationHandlerFinished = false
    private var cancellationFinished = false
    private var cancellationError: KeyboardHIDCaptureError?
    private var cancellationHandlerWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var permissionMonitor: Task<Void, Never>?

    init(
        device: IOHIDDevice,
        registryEntryID: UInt64,
        reportDescriptor: Data,
        elementPlan: KeyboardHIDElementPlan,
        focusEpochClock: FocusEpochClock,
        diagnosticHandler: (@Sendable (KeyboardHIDCaptureDiagnostic) -> Void)?
    ) {
        self.device = device
        self.registryEntryID = registryEntryID
        self.reportDescriptor = reportDescriptor
        self.elementPlan = elementPlan
        self.focusEpochClock = focusEpochClock
        self.diagnosticHandler = diagnosticHandler
        reportBuffer = .allocate(capacity: Self.inputReportBufferCapacity)
        reportBuffer.initialize(repeating: 0, count: Self.inputReportBufferCapacity)
        callbackQueue = DispatchQueue(label: "DialDeck.keyboardHIDCapture")
        let pair = AsyncStream<KeyboardHIDTransportEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferLimit)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    deinit {
        reportBuffer.deinitialize(count: Self.inputReportBufferCapacity)
        reportBuffer.deallocate()
    }

    func openReadOnly() throws {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw KeyboardHIDCaptureError.permissionUnavailable
        }
        guard Self.registryEntryID(for: device) == registryEntryID,
              Self.reportDescriptor(for: device) == reportDescriptor,
              reportDescriptor == KeyboardHIDTarget.rawReportDescriptor else {
            throw KeyboardHIDCaptureError.targetUnavailable
        }

        IOHIDDeviceSetDispatchQueue(device, callbackQueue)
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw KeyboardHIDCaptureError.openFailed
        }
        lock.withLock { hasOpenHandle = true }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            reportBuffer,
            Self.inputReportBufferCapacity,
            Self.inputReportCallback,
            context
        )
        IOHIDDeviceRegisterRemovalCallback(device, Self.deviceRemovalCallback, context)
        IOHIDDeviceSetCancelHandler(device) { [weak self] in
            self?.finishCancellationHandler()
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

    func cancel() async -> KeyboardHIDCaptureError? {
        permissionMonitor?.cancel()
        permissionMonitor = nil

        enum CancelAction {
            case begin
            case wait
            case noHandle
            case finished(KeyboardHIDCaptureError?)
        }
        let action = lock.withLock { () -> CancelAction in
            if cancellationFinished { return .finished(cancellationError) }
            if isClosing { return .wait }
            isClosing = true
            return hasOpenHandle ? .begin : .noHandle
        }

        switch action {
        case .begin:
            diagnosticHandler?(.deviceCancelIssued(registryEntryID: registryEntryID))
            IOHIDDeviceCancel(device)
            await waitForCancellationHandler()
            let wasRemoved = lock.withLock { deviceWasRemoved }
            let closeError: KeyboardHIDCaptureError?
            if wasRemoved {
                // Removal terminates the service-side link. Closing that retired
                // IOHIDDevice can return kIOReturnBadArgument; cancellation and
                // its handler are the cleanup boundary for the removed object.
                diagnosticHandler?(.deviceCloseSkippedRemoved(registryEntryID: registryEntryID))
                closeError = nil
            } else {
                let closeResult = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                diagnosticHandler?(.deviceClosed(
                    registryEntryID: registryEntryID,
                    result: Int32(closeResult)
                ))
                closeError = closeResult == kIOReturnSuccess
                    ? nil
                    : KeyboardHIDCaptureError.deviceCloseFailed(Int32(closeResult))
            }
            finishCancellation(with: closeError)
        case .wait:
            await waitForCancellation()
        case .noHandle:
            finishCancellation(with: nil)
        case .finished(let error):
            continuation.finish()
            return error
        }
        continuation.finish()
        return lock.withLock { cancellationError }
    }

    private func waitForCancellationHandler() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if cancellationHandlerFinished { return true }
                cancellationHandlerWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    private func waitForCancellation() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if cancellationFinished { return true }
                cancellationWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    private func finishCancellationHandler() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            cancellationHandlerFinished = true
            let pending = cancellationHandlerWaiters
            cancellationHandlerWaiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    private func finishCancellation(with error: KeyboardHIDCaptureError?) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            hasOpenHandle = false
            cancellationError = error
            cancellationFinished = true
            let pending = cancellationWaiters
            cancellationWaiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.resume() }
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

    private static let inputReportCallback: IOHIDReportCallback = {
        context, result, _, reportType, reportID, report, reportLength in
        guard let context else { return }
        let connection = Unmanaged<MacOSKeyboardHIDCaptureConnection>
            .fromOpaque(context)
            .takeUnretainedValue()
        let focusEpoch = connection.focusEpochClock.snapshot()
        guard result == kIOReturnSuccess, reportType == kIOHIDReportTypeInput, reportLength >= 0 else {
            connection.yield(.disconnected)
            return
        }
        let bytes = Array(UnsafeBufferPointer(start: report, count: Int(reportLength)))
        for value in connection.reportDecoder.consume(
            reportID: reportID,
            bytes: bytes,
            focusEpoch: focusEpoch
        ) {
            connection.yield(.value(value))
        }
    }

    private static let deviceRemovalCallback: IOHIDCallback = { context, _, _ in
        guard let context else { return }
        let connection = Unmanaged<MacOSKeyboardHIDCaptureConnection>
            .fromOpaque(context)
            .takeUnretainedValue()
        connection.deviceWasRemovedFromRegistry()
    }

    private func deviceWasRemovedFromRegistry() {
        let firstNotification = lock.withLock { () -> Bool in
            guard !deviceWasRemoved else { return false }
            deviceWasRemoved = true
            return true
        }
        guard firstNotification else { return }
        diagnosticHandler?(.deviceRemoved(registryEntryID: registryEntryID))
        yield(.disconnected)
    }

    private static func registryEntryID(for device: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else { return nil }
        return identifier
    }

    private static func reportDescriptor(for device: IOHIDDevice) -> Data? {
        IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
    }
}
