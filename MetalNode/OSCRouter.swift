//
//  OSCRouter.swift
//  MetalNode
//
//  Created by Codex on 4/23/26.
//

import Foundation
import Network

struct OSCMessageValue: Equatable {
    let address: String
    let arguments: [OSCValue]

    var signatureComponent: String {
        "\(address)[\(arguments.map(\.signatureComponent).joined(separator: ","))]"
    }
}

struct OSCPacketValue: Equatable {
    let messages: [OSCMessageValue]
    let forceBundle: Bool

    init(messages: [OSCMessageValue], forceBundle: Bool = false) {
        self.messages = messages
        self.forceBundle = forceBundle
    }

    var signatureComponent: String {
        let prefix = forceBundle ? "bundle" : "message"
        return "\(prefix):\(messages.map(\.signatureComponent).joined(separator: "|"))"
    }
}

final class OSCOutputRouter {
    private struct ConnectionKey: Hashable {
        let host: String
        let port: Int
    }

    private final class ConnectionContext {
        let connection: NWConnection

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "MetalNode.OSCOutput", qos: .userInitiated)
    private var connections: [ConnectionKey: ConnectionContext] = [:]

    func send(host: String, port: Int, address: String, value: OSCValue) -> Bool {
        send(host: host, port: port, address: address, values: [value])
    }

    func send(host: String, port: Int, address: String, values: [OSCValue]) -> Bool {
        send(
            host: host,
            port: port,
            packet: OSCPacketValue(
                messages: [OSCMessageValue(address: normalizedAddress(address), arguments: values)],
                forceBundle: false
            )
        )
    }

    func send(host: String, port: Int, packet: OSCPacketValue) -> Bool {
        guard packet.messages.isEmpty == false else {
            return false
        }
        let safePort = max(1, min(65535, port))
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(safePort)) else {
            return false
        }

        let content = encodePacket(packet)
        let connection = reusableConnection(host: host, port: safePort, nwPort: nwPort)
        connection.send(content: content, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.removeConnection(host: host, port: safePort)
            }
        })
        return true
    }

    private func reusableConnection(host: String, port: Int, nwPort: NWEndpoint.Port) -> NWConnection {
        let key = ConnectionKey(host: host, port: port)

        lock.lock()
        if let existing = connections[key] {
            lock.unlock()
            return existing.connection
        }
        lock.unlock()

        let endpointHost = NWEndpoint.Host(host)
        let connection = NWConnection(host: endpointHost, port: nwPort, using: .udp)
        let context = ConnectionContext(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removeConnection(host: host, port: port)
            default:
                break
            }
        }
        connection.start(queue: queue)

        lock.lock()
        connections[key] = context
        lock.unlock()

        return connection
    }

    private func removeConnection(host: String, port: Int) {
        let key = ConnectionKey(host: host, port: port)

        lock.lock()
        let context = connections.removeValue(forKey: key)
        lock.unlock()

        context?.connection.cancel()
    }

    private func normalizedAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "/value" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private func encodeMessage(address: String, arguments: [OSCValue]) -> Data {
        var data = Data()
        appendPaddedString(address, to: &data)
        let typeTag = "," + arguments.map(\.typeTag).joined()
        appendPaddedString(typeTag, to: &data)

        for argument in arguments {
            switch argument {
            case .float(let value):
                appendUInt32(value.bitPattern, to: &data)
            case .int(let value):
                appendUInt32(UInt32(bitPattern: value), to: &data)
            case .string(let value):
                appendPaddedString(value, to: &data)
            }
        }

        return data
    }

    private func encodePacket(_ packet: OSCPacketValue) -> Data {
        if packet.messages.count == 1, packet.forceBundle == false, let message = packet.messages.first {
            return encodeMessage(address: normalizedAddress(message.address), arguments: message.arguments)
        }

        var data = Data()
        appendPaddedString("#bundle", to: &data)
        for _ in 0..<8 {
            data.append(0)
        }

        for message in packet.messages {
            let encodedMessage = encodeMessage(address: normalizedAddress(message.address), arguments: message.arguments)
            appendUInt32(UInt32(encodedMessage.count), to: &data)
            data.append(encodedMessage)
        }

        return data
    }

    private func appendPaddedString(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
        data.append(0)
        while data.count % 4 != 0 {
            data.append(0)
        }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

final class OSCInputRouter {
    struct Message: Equatable {
        let id: UInt64
        let port: Int
        let address: String
        let arguments: [OSCValue]
    }

    private final class ListenerContext {
        let listener: NWListener
        var connections: [ObjectIdentifier: NWConnection] = [:]

        init(listener: NWListener) {
            self.listener = listener
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "MetalNode.OSCInput", qos: .userInitiated)
    private var listeners: [Int: ListenerContext] = [:]
    private var latestMessageByPort: [Int: Message] = [:]
    private var latestMessageByPortAndAddress: [Int: [String: Message]] = [:]
    private var latestPacketByPort: [Int: OSCPacketValue] = [:]
    private var latestPacketByPortAndAddress: [Int: [String: OSCPacketValue]] = [:]
    private var eventCounter: UInt64 = 0

    func syncListening(on ports: Set<Int>) {
        let safePorts = Set(ports.map { max(1, min(65535, $0)) })

        lock.lock()
        let existingPorts = Set(listeners.keys)
        lock.unlock()

        for port in existingPorts.subtracting(safePorts) {
            removeListener(on: port)
        }

        for port in safePorts {
            ensureListening(on: port)
        }
    }

    func restartListening(on ports: Set<Int>) {
        let safePorts = Set(ports.map { max(1, min(65535, $0)) })

        lock.lock()
        let existingPorts = Array(listeners.keys)
        lock.unlock()

        for port in existingPorts {
            removeListener(on: port)
        }

        for port in safePorts {
            ensureListening(on: port)
        }
    }

    func ensureListening(on port: Int) {
        let safePort = max(1, min(65535, port))

        lock.lock()
        if listeners[safePort] != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(safePort)) else { return }

        do {
            let listener = try NWListener(using: .udp, on: nwPort)
            let context = ListenerContext(listener: listener)

            listener.newConnectionHandler = { [weak self, weak context] connection in
                guard let self, let context else { return }
                self.attach(connection: connection, to: context, port: safePort)
            }

            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.removeListener(on: safePort)
                }
            }

            lock.lock()
            listeners[safePort] = context
            lock.unlock()

            listener.start(queue: queue)
        } catch {
            return
        }
    }

    func latestMessage(port: Int, address: String?) -> Message? {
        let safePort = max(1, min(65535, port))
        ensureListening(on: safePort)

        lock.lock()
        defer { lock.unlock() }

        guard let address, address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return latestMessageByPort[safePort]
        }

        let normalized = normalizedAddress(address)
        return latestMessageByPortAndAddress[safePort]?[normalized]
    }

    func latestPacket(port: Int, address: String?) -> OSCPacketValue? {
        let safePort = max(1, min(65535, port))
        ensureListening(on: safePort)

        lock.lock()
        defer { lock.unlock() }

        guard let address, address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return latestPacketByPort[safePort]
        }

        let normalized = normalizedAddress(address)
        return latestPacketByPortAndAddress[safePort]?[normalized]
    }

    private func attach(connection: NWConnection, to context: ListenerContext, port: Int) {
        let identifier = ObjectIdentifier(connection)

        lock.lock()
        context.connections[identifier] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self, weak context] state in
            switch state {
            case .ready:
                self?.receive(on: connection, port: port, context: context)
            case .failed, .cancelled:
                self?.remove(connection: connection, from: context)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, port: Int, context: ListenerContext?) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }

            if let data {
                let packet = self.decodePacketValue(data)
                let messages = self.decodeMessages(data, port: port)
                self.lock.lock()
                if let packet {
                    self.latestPacketByPort[port] = packet
                    var packetsForPort = self.latestPacketByPortAndAddress[port] ?? [:]
                    let grouped = Dictionary(grouping: packet.messages, by: \.address)
                    for (address, messages) in grouped {
                        packetsForPort[address] = OSCPacketValue(messages: messages, forceBundle: messages.count > 1)
                    }
                    self.latestPacketByPortAndAddress[port] = packetsForPort
                }
                for message in messages {
                    self.latestMessageByPort[port] = message
                    var messagesForPort = self.latestMessageByPortAndAddress[port] ?? [:]
                    messagesForPort[message.address] = message
                    self.latestMessageByPortAndAddress[port] = messagesForPort
                }
                self.lock.unlock()
            }

            if error != nil {
                self.remove(connection: connection, from: context)
                return
            }

            self.receive(on: connection, port: port, context: context)
        }
    }

    private func remove(connection: NWConnection, from context: ListenerContext?) {
        let identifier = ObjectIdentifier(connection)
        lock.lock()
        context?.connections.removeValue(forKey: identifier)
        lock.unlock()
        connection.cancel()
    }

    private func removeListener(on port: Int) {
        lock.lock()
        let context = listeners.removeValue(forKey: port)
        latestMessageByPort.removeValue(forKey: port)
        latestMessageByPortAndAddress.removeValue(forKey: port)
        latestPacketByPort.removeValue(forKey: port)
        latestPacketByPortAndAddress.removeValue(forKey: port)
        lock.unlock()

        context?.listener.cancel()
        context?.connections.values.forEach { $0.cancel() }
    }

    private func normalizedAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private struct RawMessage {
        let address: String
        let arguments: [OSCValue]
    }

    private func decodeMessages(_ data: Data, port: Int) -> [Message] {
        let rawMessages = decodePacket(data)
        guard rawMessages.isEmpty == false else { return [] }

        return rawMessages.map { raw in
            Message(
                id: nextEventID(),
                port: port,
                address: raw.address,
                arguments: raw.arguments
            )
        }
    }

    private func decodePacketValue(_ data: Data) -> OSCPacketValue? {
        let rawMessages = decodePacket(data)
        guard rawMessages.isEmpty == false else { return nil }

        return OSCPacketValue(
            messages: rawMessages.map { OSCMessageValue(address: $0.address, arguments: $0.arguments) },
            forceBundle: data.starts(with: Array("#bundle".utf8)) || rawMessages.count > 1
        )
    }

    private func decodePacket(_ data: Data) -> [RawMessage] {
        if data.starts(with: Array("#bundle".utf8)) {
            return decodeBundle(data)
        }

        if let message = decodeMessage(data) {
            return [message]
        }

        return []
    }

    private func decodeMessage(_ data: Data) -> RawMessage? {
        var offset = 0
        guard let address = readPaddedString(from: data, offset: &offset),
              address.hasPrefix("/"),
              let typeTag = readPaddedString(from: data, offset: &offset),
              typeTag.hasPrefix(",") else {
            return nil
        }

        var arguments: [OSCValue] = []
        for character in typeTag.dropFirst() {
            switch character {
            case "f":
                guard let raw = readUInt32(from: data, offset: &offset) else { return nil }
                arguments.append(.float(Float(bitPattern: raw)))
            case "i":
                guard let raw = readUInt32(from: data, offset: &offset) else { return nil }
                arguments.append(.int(Int32(bitPattern: raw)))
            case "s":
                guard let string = readPaddedString(from: data, offset: &offset) else { return nil }
                arguments.append(.string(string))
            default:
                return nil
            }
        }

        return RawMessage(address: address, arguments: arguments)
    }

    private func decodeBundle(_ data: Data) -> [RawMessage] {
        var offset = 0
        guard let bundleTag = readPaddedString(from: data, offset: &offset), bundleTag == "#bundle" else {
            return []
        }

        guard offset + 8 <= data.count else { return [] }
        offset += 8 // Skip timetag.

        var messages: [RawMessage] = []
        while offset < data.count {
            guard let elementSize = readUInt32(from: data, offset: &offset) else { break }
            let size = Int(elementSize)
            guard size > 0, offset + size <= data.count else { break }
            let elementData = data.subdata(in: offset..<(offset + size))
            messages.append(contentsOf: decodePacket(elementData))
            offset += size
        }

        return messages
    }

    private func nextEventID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        eventCounter &+= 1
        return eventCounter
    }

    private func readPaddedString(from data: Data, offset: inout Int) -> String? {
        guard offset < data.count else { return nil }
        let start = offset
        guard let terminator = data[start...].firstIndex(of: 0) else { return nil }
        let stringData = data[start..<terminator]
        let string = String(data: stringData, encoding: .utf8) ?? ""
        let nextOffset = terminator + 1
        offset = ((nextOffset + 3) / 4) * 4
        return string
    }

    private func readUInt32(from data: Data, offset: inout Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let b0 = UInt32(data[offset]) << 24
        let b1 = UInt32(data[offset + 1]) << 16
        let b2 = UInt32(data[offset + 2]) << 8
        let b3 = UInt32(data[offset + 3])
        offset += 4
        return b0 | b1 | b2 | b3
    }

    private func appendPaddedString(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
        data.append(0)
        while data.count % 4 != 0 {
            data.append(0)
        }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

enum OSCValue: Equatable {
    case float(Float)
    case int(Int32)
    case string(String)

    var typeTag: String {
        switch self {
        case .float:
            return "f"
        case .int:
            return "i"
        case .string:
            return "s"
        }
    }

    var signatureComponent: String {
        switch self {
        case .float(let value):
            return "f:\(value)"
        case .int(let value):
            return "i:\(value)"
        case .string(let value):
            return "s:\(value)"
        }
    }
}
