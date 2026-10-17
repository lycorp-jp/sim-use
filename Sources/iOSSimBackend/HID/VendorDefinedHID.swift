// SPDX-License-Identifier: Apache-2.0
@preconcurrency import CoreSimulator
import Darwin
import FBSimulatorControl
import Foundation
import IOKit
import SimUseCore
import XPC

/// A report from one of the controls of the simulator's virtual-machine
/// provider. Device Hub's hinge slider and orientation picker send these,
/// and `locationd` turns them into a hinge angle or a device orientation.
///
/// Wire format and payload keys match upstream idb
/// (`IndigoVendorDefinedEvent.virtualMachineControl`), so the idb migration
/// can replace this file without a behaviour change. Work record:
/// docs/ai/010-display-routing/000-plan.md (E1, E2).
public enum VirtualMachineControl: Equatable, Sendable {
    /// 0 (closed) … 180 (flat), degrees.
    case hinge(degrees: Double)
    /// A device orientation in the provider's vocabulary.
    case orientation(VirtualMachineOrientation)

    var source: String {
        switch self {
        case .hinge: return "hinge-slider-control"
        case .orientation: return "orientation-picker-control"
        }
    }

    /// The dictionary the provider reads.
    var payload: [String: Any] {
        switch self {
        case .hinge(let degrees):
            return ["provider": Self.provider, "source": source, "type": "range", "value": degrees]
        case .orientation(let orientation):
            return ["provider": Self.provider, "source": source, "type": "enum", "value": orientation.rawValue]
        }
    }

    static let provider = "com.apple.Virtualization.VirtualMachines"
    static let usagePage: UInt64 = 0xFF61
    static let usage: UInt64 = 0x5B

    /// The payload as an IOKit binary property list (`OSSerializeBinary`),
    /// the format the vendor report carries.
    func serializedPayload() throws -> Data {
        guard let serialized = IOCFSerialize(payload as CFDictionary, CFOptionFlags(kIOCFSerializeToBinary)) else {
            throw CLIError(errorDescription: "Could not serialise the \(source) report.")
        }
        return serialized as Data
    }
}

/// Device orientations the orientation picker accepts. Device convention:
/// `landscapeLeft` here turns the interface to sim-use's `landscape-right`.
public enum VirtualMachineOrientation: String, Equatable, Sendable {
    case portrait
    case portraitUpsideDown = "pud"
    case landscapeLeft = "landscape-left"
    case landscapeRight = "landscape-right"
}

/// Sends vendor-defined HID reports to the simulator's `dtuhidd` over the
/// host-to-guest XPC service `com.apple.coredevice.feature.remote.hid.vendordefined`,
/// the path Device Hub uses. Device Hub does not need to be running.
///
/// One connection per send: hinge and orientation changes are rare and
/// confirmed by reading CoreDevice state back, and a dead cached
/// connection after a reboot would fail silently.
public enum VendorDefinedHID {
    public static let serviceName = "com.apple.coredevice.feature.remote.hid.vendordefined"

    /// How long the connection stays open after the barrier reply, so the
    /// guest picks the report up before dtuhidd removes the connection's
    /// services (a new peer's services take ~0.8 s to appear — plan E5).
    static let settleNanos: UInt64 = 1_000_000_000

    public static func send(_ control: VirtualMachineControl, to simulator: FBSimulator, logger: SimUseLogger) async throws {
        let data = try control.serializedPayload()
        let connection = try connect(to: simulator)
        defer { xpc_connection_cancel(connection) }

        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usagePage", VirtualMachineControl.usagePage)
        xpc_dictionary_set_uint64(payload, "usage", VirtualMachineControl.usage)
        xpc_dictionary_set_uint64(payload, "version", 0)
        data.withUnsafeBytes { buffer in
            xpc_dictionary_set_data(payload, "data", buffer.baseAddress!, buffer.count)
        }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", "IndigoVendorDefinedEvent")
        xpc_dictionary_set_bool(message, "isBarrier", false)
        xpc_dictionary_set_string(message, "featureIdentifier", serviceName)
        xpc_dictionary_set_value(message, "payload", payload)
        logger.info().log("Sending \(control.source) report to \(serviceName)")
        xpc_connection_send_message(connection, message)

        // dtuhidd answers a barrier once everything sent before it has
        // been dispatched.
        let barrier = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(barrier, "isBarrier", true)
        let reply: xpc_object_t = await withCheckedContinuation { continuation in
            xpc_connection_send_message_with_reply(connection, barrier, nil) { reply in
                continuation.resume(returning: reply)
            }
        }
        if xpc_get_type(reply) == XPC_TYPE_ERROR {
            let description = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION).map { String(cString: $0) } ?? "unknown error"
            throw CLIError(errorDescription: "dtuhidd did not acknowledge the \(control.source) report: \(description)")
        }
        try? await Task.sleep(nanoseconds: settleNanos)
    }

    /// Starts the simulator's dtuhidd, if it is not running, by sending a
    /// barrier to its XPC service: launchd starts the daemon on demand, as
    /// for a fold report. No report is sent.
    public static func startDtuhidd(on simulator: FBSimulator, logger: SimUseLogger) async throws {
        let connection = try connect(to: simulator)
        defer { xpc_connection_cancel(connection) }
        let barrier = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(barrier, "isBarrier", true)
        let reply: xpc_object_t = await withCheckedContinuation { continuation in
            xpc_connection_send_message_with_reply(connection, barrier, nil) { reply in
                continuation.resume(returning: reply)
            }
        }
        if xpc_get_type(reply) == XPC_TYPE_ERROR {
            let description = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION).map { String(cString: $0) } ?? "unknown error"
            throw CLIError(errorDescription: "dtuhidd in simulator \(simulator.udid) did not answer: \(description)")
        }
        logger.info().log("dtuhidd answered in \(simulator.udid)")
    }

    // MARK: Connection

    private typealias EndpointFromMachPortFn = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
    private typealias ConnectionFromEndpointFn = @convention(c) (xpc_object_t) -> xpc_connection_t?
    private typealias EnableSim2HostFn = @convention(c) (xpc_connection_t) -> Void

    private static func connect(to simulator: FBSimulator) throws -> xpc_connection_t {
        guard let handle = dlopen(nil, RTLD_NOW),
              let endpointFromPort = symbol(handle, "xpc_endpoint_create_mach_port_4sim", as: EndpointFromMachPortFn.self),
              let connectionFromEndpoint = symbol(handle, "xpc_connection_create_from_endpoint", as: ConnectionFromEndpointFn.self),
              let enableSim2Host = symbol(handle, "xpc_connection_enable_sim2host_4sim", as: EnableSim2HostFn.self)
        else {
            throw CLIError(errorDescription: "The host-to-simulator XPC symbols are not available on this macOS.")
        }

        let port = try lookup(serviceName, on: simulator)
        guard let endpoint = endpointFromPort(port, 0, 0),
              let connection = connectionFromEndpoint(endpoint)
        else {
            throw CLIError(errorDescription: "Could not open an XPC connection to \(serviceName) in simulator \(simulator.udid).")
        }
        // Without this the daemon sees the peer but never the payload.
        enableSim2Host(connection)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        return connection
    }

    private static func lookup(_ service: String, on simulator: FBSimulator) throws -> mach_port_t {
        var error: NSError?
        let port = simulator.device.lookup(service, error: &error)
        guard port != MACH_PORT_NULL else {
            let reason = error?.localizedDescription ?? "the service is not registered"
            throw CLIError(errorDescription: "Simulator \(simulator.udid) has no \(service) service (\(reason)). It needs an Xcode 27 runtime with dtuhidd.")
        }
        return port
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
        guard let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }
}
