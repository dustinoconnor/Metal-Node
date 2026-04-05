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
