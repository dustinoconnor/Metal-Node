//
//  MIDIOutputRouter.swift
//  MetalNode
//
//  Created by Codex on 3/20/26.
//

import CoreMIDI
import Foundation

final class MIDIOutputRouter {
    struct Destination: Identifiable, Equatable {
        let id: MIDIUniqueID
        let name: String
        let endpoint: MIDIEndpointRef
    }

    private var client = MIDIClientRef()
    private var outputPort = MIDIPortRef()

    init() {
        MIDIClientCreateWithBlock("MetalNode MIDI" as CFString, &client) { _ in }
        MIDIOutputPortCreate(client, "MetalNode Output" as CFString, &outputPort)
    }

    deinit {
        if outputPort != 0 {
            MIDIPortDispose(outputPort)
        }
        if client != 0 {
            MIDIClientDispose(client)
        }
    }

    var destinationNames: [String] {
        destinations().map(\.name)
    }

    func preferredDestinationName() -> String? {
        let destinations = destinations()
        return destinations.first(where: { $0.name.localizedCaseInsensitiveContains("IAC") })?.name
            ?? destinations.first?.name
    }

    func sendNoteOn(note: UInt8, velocity: UInt8, channel: UInt8, destinationName: String?) -> Bool {
        send(status: 0x90 | (channel & 0x0F), data1: note, data2: velocity, destinationName: destinationName)
    }

    func sendNoteOff(note: UInt8, channel: UInt8, destinationName: String?) -> Bool {
        send(status: 0x80 | (channel & 0x0F), data1: note, data2: 0, destinationName: destinationName)
    }

    func sendCC(controller: UInt8, value: UInt8, channel: UInt8, destinationName: String?) -> Bool {
        send(status: 0xB0 | (channel & 0x0F), data1: controller, data2: value, destinationName: destinationName)
    }

    private func destinations() -> [Destination] {
        let count = MIDIGetNumberOfDestinations()
        return (0..<count).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { return nil }

            var nameRef: Unmanaged<CFString>?
            let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &nameRef)
            let name = status == noErr ? (nameRef?.takeRetainedValue() as String?) : nil

            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)

            return Destination(
                id: uniqueID,
                name: name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name! : "Destination \(index + 1)",
                endpoint: endpoint
            )
        }
    }

    private func destination(named requestedName: String?) -> Destination? {
        let all = destinations()
        guard !all.isEmpty else { return nil }

        if let requestedName,
           !requestedName.isEmpty,
           let destination = all.first(where: { $0.name == requestedName }) {
            return destination
        }

        if let preferred = all.first(where: { $0.name.localizedCaseInsensitiveContains("IAC") }) {
            return preferred
        }

        return all.first
    }

    private func send(status: UInt8, data1: UInt8, data2: UInt8, destinationName: String?) -> Bool {
        guard let destination = destination(named: destinationName), outputPort != 0 else {
            return false
        }

        let bufferSize = 1024
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { rawPointer.deallocate() }

        let packetListPointer = rawPointer.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(packetListPointer)
        var bytes: [UInt8] = [status, data1, data2]
        packet = MIDIPacketListAdd(packetListPointer, bufferSize, packet, 0, bytes.count, &bytes)
        return MIDISend(outputPort, destination.endpoint, packetListPointer) == noErr
    }
}

final class MIDIInputRouter {
    struct MIDIEvent: Equatable {
        enum Kind: Equatable {
            case controlChange(controller: UInt8, value: UInt8)
            case noteOn(note: UInt8, velocity: UInt8)
            case noteOff(note: UInt8)
        }

        let id: UInt64
        let channel: UInt8
        let kind: Kind
    }

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private let lock = NSLock()
    private var connectedSourceIDs: Set<MIDIUniqueID> = []
    private var eventCounter: UInt64 = 0
    private var latestCCEvents: [String: MIDIEvent] = [:]
    private var latestNoteEvent: MIDIEvent?
    private var activeNoteVelocities: [String: UInt8] = [:]

    init() {
        MIDIClientCreateWithBlock("MetalNode MIDI Input" as CFString, &client) { [weak self] _ in
            self?.refreshSources()
        }
        MIDIInputPortCreateWithBlock(client, "MetalNode Input" as CFString, &inputPort) { [weak self] packetList, _ in
            self?.handle(packetList: packetList)
        }
        refreshSources()
    }

    deinit {
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
        }
        if client != 0 {
            MIDIClientDispose(client)
        }
    }

    var sourceNames: [String] {
        sources().map(\.name)
    }

    func refreshSources() {
        guard inputPort != 0 else { return }
        let currentSources = sources()
        let currentIDs = Set(currentSources.map(\.id))

        for source in currentSources where connectedSourceIDs.contains(source.id) == false {
            MIDIPortConnectSource(inputPort, source.endpoint, nil)
        }

        for staleID in connectedSourceIDs.subtracting(currentIDs) {
            if let source = source(for: staleID) {
                MIDIPortDisconnectSource(inputPort, source.endpoint)
            }
        }

        connectedSourceIDs = currentIDs
    }

    func latestCCEvent(channel: Int?, controller: Int) -> MIDIEvent? {
        lock.lock()
        defer { lock.unlock() }

        if let channel {
            return latestCCEvents[ccKey(channel: UInt8(channel), controller: UInt8(controller))]
        }

        return latestCCEvents.values
            .filter {
                if case .controlChange(let eventController, _) = $0.kind {
                    return eventController == UInt8(controller)
                }
                return false
            }
            .max { lhs, rhs in lhs.id < rhs.id }
    }

    func latestNoteEvent(channel: Int?, note: Int?) -> MIDIEvent? {
        lock.lock()
        defer { lock.unlock() }

        guard let event = latestNoteEvent else { return nil }
        guard channel.map({ UInt8($0) == event.channel }) ?? true else { return nil }
        if let note {
            switch event.kind {
            case .noteOn(let eventNote, _), .noteOff(let eventNote):
                return eventNote == UInt8(note) ? event : nil
            case .controlChange:
                return nil
            }
        }
        return event
    }

    func activeNoteVelocity(channel: Int?, note: Int?) -> UInt8? {
        lock.lock()
        defer { lock.unlock() }

        if let channel, let note {
            return activeNoteVelocities[noteKey(channel: UInt8(channel), note: UInt8(note))]
        }

        let filtered = activeNoteVelocities.compactMap { key, value -> UInt8? in
            let parts = key.split(separator: ":")
            guard parts.count == 2 else { return nil }
            if let channel, parts[0] != "\(channel)" { return nil }
            if let note, parts[1] != "\(note)" { return nil }
            return value
        }
        return filtered.max()
    }

    private struct Source {
        let id: MIDIUniqueID
        let name: String
        let endpoint: MIDIEndpointRef
    }

    private func sources() -> [Source] {
        let count = MIDIGetNumberOfSources()
        return (0..<count).compactMap { index in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { return nil }

            var nameRef: Unmanaged<CFString>?
            let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &nameRef)
            let name = status == noErr ? (nameRef?.takeRetainedValue() as String?) : nil

            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)

            return Source(
                id: uniqueID,
                name: name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name! : "Source \(index + 1)",
                endpoint: endpoint
            )
        }
    }

    private func source(for id: MIDIUniqueID) -> Source? {
        sources().first { $0.id == id }
    }

    private func handle(packetList: UnsafePointer<MIDIPacketList>) {
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            withUnsafePointer(to: &packet.data) { dataPointer in
                let bytes = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)
                handle(bytes: bytes, count: Int(packet.length))
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private func handle(bytes: UnsafePointer<UInt8>, count: Int) {
        var index = 0
        while index + 2 < count {
            let status = bytes[index]
            let message = status & 0xF0
            let channel = status & 0x0F
            let data1 = bytes[index + 1]
            let data2 = bytes[index + 2]

            switch message {
            case 0x80:
                record(event: .init(id: nextEventID(), channel: channel, kind: .noteOff(note: data1)))
            case 0x90:
                if data2 == 0 {
                    record(event: .init(id: nextEventID(), channel: channel, kind: .noteOff(note: data1)))
                } else {
                    record(event: .init(id: nextEventID(), channel: channel, kind: .noteOn(note: data1, velocity: data2)))
                }
            case 0xB0:
                record(event: .init(id: nextEventID(), channel: channel, kind: .controlChange(controller: data1, value: data2)))
            default:
                break
            }

            index += 3
        }
    }

    private func nextEventID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        eventCounter &+= 1
        return eventCounter
    }

    private func record(event: MIDIEvent) {
        lock.lock()
        defer { lock.unlock() }

        switch event.kind {
        case .controlChange(let controller, _):
            latestCCEvents[ccKey(channel: event.channel, controller: controller)] = event
        case .noteOn(let note, let velocity):
            latestNoteEvent = event
            activeNoteVelocities[noteKey(channel: event.channel, note: note)] = velocity
        case .noteOff(let note):
            latestNoteEvent = event
            activeNoteVelocities.removeValue(forKey: noteKey(channel: event.channel, note: note))
        }
    }

    private func ccKey(channel: UInt8, controller: UInt8) -> String {
        "\(channel):\(controller)"
    }

    private func noteKey(channel: UInt8, note: UInt8) -> String {
        "\(channel):\(note)"
    }
}
