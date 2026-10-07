import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem
import XCTest

private let expectedKeyboardRegistryIDs: Set<UInt64> = [4_295_598_773, 4_295_598_769]
private let rawReportOutputRelativePath = ".apm/evidence/hardware/hid-raw-reports-2026-10-06.md"
private let rawReportCaptureDuration: CFTimeInterval = 60
private let rawReportBufferCapacity = 256
private let captureRunLoopMode = CFRunLoopMode.defaultMode!

private final class RawReportCaptureLog {
    private let lock = NSLock()
    private var reports: [String] = []

    func append(registryEntryID: UInt64, result: IOReturn, reportID: UInt32, bytes: [UInt8]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let resultHex = iorReturn(result)
        lock.lock()
        reports.append("- \(timestamp) registryEntryID=\(registryEntryID) reportID=\(reportID) result=\(resultHex) length=\(bytes.count) rawReportHex=\(hex)")
        lock.unlock()
    }

    func reportLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }
}

private final class RawReportCallbackContext {
    let registryEntryID: UInt64
    let log: RawReportCaptureLog

    init(registryEntryID: UInt64, log: RawReportCaptureLog) {
        self.registryEntryID = registryEntryID
        self.log = log
    }
}

private struct RawReportCaptureDevice {
    let device: IOHIDDevice
    let registryEntryID: UInt64
    let reportBuffer: UnsafeMutablePointer<UInt8>
}

final class KeyboardHIDRawReportCaptureTests: XCTestCase {
    func testOptInCaptureRawReportsFromBothTargetKeyboardChildren() throws {
        guard ProcessInfo.processInfo.environment["DIALDECK_RUN_RAW_REPORT_CAPTURE"] == "1" else {
            throw XCTSkip("Set DIALDECK_RUN_RAW_REPORT_CAPTURE=1 for the supervised raw-report capture.")
        }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw XCTSkip("Input Monitoring is not already granted; no permission request was made.")
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: NSNumber(value: 0x1189),
            kIOHIDProductIDKey as String: NSNumber(value: 0x8890),
            kIOHIDTransportKey as String: kIOHIDTransportUSBValue,
            kIOHIDDeviceUsagePageKey as String: NSNumber(value: 0x01),
            kIOHIDDeviceUsageKey as String: NSNumber(value: 0x06),
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let managerOpenResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard managerOpenResult == kIOReturnSuccess else {
            XCTFail("Target-only non-seizing manager open failed: \(iorReturn(managerOpenResult))")
            return
        }

        var devices: [RawReportCaptureDevice] = []
        var openedDevices: [IOHIDDevice] = []
        var scheduledDevices: [IOHIDDevice] = []
        var managerCloseAttempted = false
        var managerCloseResult: IOReturn?
        defer {
            for device in scheduledDevices.reversed() {
                IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), captureRunLoopMode.rawValue as CFString)
            }
            for device in openedDevices.reversed() {
                let closeResult = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                XCTAssertEqual(closeResult, kIOReturnSuccess, "Deferred device close failed: \(iorReturn(closeResult))")
            }
            if !managerCloseAttempted {
                managerCloseAttempted = true
                let closeResult = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                managerCloseResult = closeResult
                XCTAssertEqual(closeResult, kIOReturnSuccess, "Deferred HID manager close failed: \(iorReturn(closeResult))")
            }
            for item in devices {
                item.reportBuffer.deinitialize(count: rawReportBufferCapacity)
                item.reportBuffer.deallocate()
            }
        }

        guard let rawDevices = IOHIDManagerCopyDevices(manager) else {
            XCTFail("IOHIDManagerCopyDevices returned no matching devices.")
            return
        }
        let matchingDevices = ((rawDevices as NSSet).allObjects as? [IOHIDDevice] ?? [])
            .compactMap { device -> (UInt64, IOHIDDevice)? in
                guard isTargetKeyboard(device),
                      let entryID = registryEntryID(for: device),
                      expectedKeyboardRegistryIDs.contains(entryID) else { return nil }
                return (entryID, device)
            }
            .sorted { $0.0 < $1.0 }
        guard Set(matchingDevices.map(\.0)) == expectedKeyboardRegistryIDs,
              matchingDevices.count == expectedKeyboardRegistryIDs.count else {
            XCTFail("Expected exactly target keyboard children \(expectedKeyboardRegistryIDs.sorted()), found \(matchingDevices.map(\.0).sorted()).")
            return
        }

        managerCloseAttempted = true
        let closeResult = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        managerCloseResult = closeResult
        guard closeResult == kIOReturnSuccess else {
            XCTFail("Target-only HID manager close before direct child opens failed: \(iorReturn(closeResult))")
            return
        }

        let log = RawReportCaptureLog()
        var callbackContexts: [RawReportCallbackContext] = []
        var deviceOpenResults: [String] = []
        for (entryID, device) in matchingDevices {
            let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: rawReportBufferCapacity)
            reportBuffer.initialize(repeating: 0, count: rawReportBufferCapacity)
            devices.append(RawReportCaptureDevice(
                device: device,
                registryEntryID: entryID,
                reportBuffer: reportBuffer
            ))

            let deviceOpenResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            deviceOpenResults.append("registryEntryID=\(entryID):\(iorReturn(deviceOpenResult))")
            guard deviceOpenResult == kIOReturnSuccess else {
                XCTFail("Non-seizing open failed for registryEntryID \(entryID): \(iorReturn(deviceOpenResult))")
                return
            }
            openedDevices.append(device)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), captureRunLoopMode.rawValue as CFString)
            scheduledDevices.append(device)

            let callbackContext = RawReportCallbackContext(registryEntryID: entryID, log: log)
            callbackContexts.append(callbackContext)
            IOHIDDeviceRegisterInputReportCallback(
                device,
                reportBuffer,
                rawReportBufferCapacity,
                rawReportCallback,
                Unmanaged.passUnretained(callbackContext).toOpaque()
            )
        }

        print("RAW_REPORT_CAPTURE_READY: both specified children are open non-seizing with input-report callbacks registered. Press and release each key once in order: top-left, top-right, middle-left, middle-right, bottom-left, bottom-right; then one clockwise knob click, one counterclockwise knob click, and one knob press. The capture window is 60 seconds.")

        let deadline = CFAbsoluteTimeGetCurrent() + rawReportCaptureDuration
        withExtendedLifetime(callbackContexts) {
            while CFAbsoluteTimeGetCurrent() < deadline {
                _ = CFRunLoopRunInMode(captureRunLoopMode, 0.25, true)
            }
        }

        for device in scheduledDevices.reversed() {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), captureRunLoopMode.rawValue as CFString)
        }
        scheduledDevices.removeAll()
        let devicesToClose = openedDevices.reversed()
        openedDevices.removeAll()
        let deviceCloseResults = devicesToClose.map { device in
            (registryEntryID(for: device) ?? 0, IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)))
        }
        for (entryID, result) in deviceCloseResults {
            XCTAssertEqual(result, kIOReturnSuccess, "Close failed for registryEntryID \(entryID): \(iorReturn(result))")
        }

        let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(rawReportOutputRelativePath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let lines = [
            "# Read-only HID raw input report capture",
            "",
            "- Target: USB keyboard VID 0x1189, PID 0x8890.",
            "- Children: registry entry IDs \(expectedKeyboardRegistryIDs.sorted().map { String($0) }.joined(separator: ", ")).",
            "- Access: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) was already granted.",
            "- Opens: IOHIDManagerOpen and both IOHIDDeviceOpen calls used kIOHIDOptionsTypeNone; no seize option was used.",
            "- Device open results: \(deviceOpenResults.joined(separator: "; ")).",
            "- Capture: IOHIDDeviceRegisterInputReportCallback on both children for \(rawReportCaptureDuration) seconds.",
            "- Scope: raw input reports from the two target children only; no output, feature, configuration, or flash reports were sent.",
            "- Manager close result (before direct child opens): \(managerCloseResult.map(iorReturn) ?? "unavailable").",
            "- Device close results: \(deviceCloseResults.map { "registryEntryID=\($0.0):\(iorReturn($0.1))" }.joined(separator: ", ")).",
            "",
            "## Reports",
            "",
        ] + log.reportLines()
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: outputURL, options: .atomic)

        XCTAssertTrue(deviceCloseResults.allSatisfy { $0.1 == kIOReturnSuccess }, "One or more child closes failed.")
        XCTAssertEqual(managerCloseResult, kIOReturnSuccess, "The target-only HID manager close failed.")
        XCTAssertFalse(log.reportLines().isEmpty, "No raw input reports were received from the two target children.")
        print("RAW_REPORT_CAPTURE_WRITTEN path=\(outputURL.path) reports=\(log.reportLines().count)")
    }
}

private let rawReportCallback: IOHIDReportCallback = {
    context, result, _, _, reportID, report, reportLength in
    guard let context, reportLength >= 0 else { return }
    let captureContext = Unmanaged<RawReportCallbackContext>.fromOpaque(context).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: report, count: Int(reportLength)))
    captureContext.log.append(
        registryEntryID: captureContext.registryEntryID,
        result: result,
        reportID: reportID,
        bytes: bytes
    )
}

private func isTargetKeyboard(_ device: IOHIDDevice) -> Bool {
    (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.uint32Value == 0x1189
        && (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.uint32Value == 0x8890
        && (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) == kIOHIDTransportUSBValue
        && IOHIDDeviceConformsTo(device, 0x01, 0x06)
}

private func registryEntryID(for device: IOHIDDevice) -> UInt64? {
    let service = IOHIDDeviceGetService(device)
    guard service != IO_OBJECT_NULL else { return nil }
    var identifier: UInt64 = 0
    guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else { return nil }
    return identifier
}

private func iorReturn(_ value: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: value))
}
