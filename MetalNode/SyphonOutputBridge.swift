//
//  SyphonOutputBridge.swift
//  MetalNode
//
//  Created by Codex on 5/29/26.
//

import AppKit
import Foundation
import Metal

#if canImport(Syphon)
import Syphon
#endif

final class SyphonOutputBridge {
    private(set) var serverName: String

    #if canImport(Syphon)
    private var server: SyphonMetalServer?
    private var deviceID: ObjectIdentifier?
    private var hasLoggedServerStart = false
    #endif

    init(serverName: String) {
        self.serverName = serverName
    }

    func rename(to serverName: String) {
        guard self.serverName != serverName else { return }
        self.serverName = serverName

        #if canImport(Syphon)
        server = nil
        deviceID = nil
        hasLoggedServerStart = false
        #endif
    }

    func publish(texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        #if canImport(Syphon)
        let currentDeviceID = ObjectIdentifier(texture.device as AnyObject)
        if server == nil || deviceID != currentDeviceID {
            server = SyphonMetalServer(name: serverName, device: texture.device, options: nil)
            deviceID = currentDeviceID
            if let server {
                let publishedName = server.name ?? serverName
                print("Syphon server started: \(publishedName) \(server.serverDescription)")
                hasLoggedServerStart = true
            } else if hasLoggedServerStart == false {
                print("Syphon server failed to start: \(serverName)")
                hasLoggedServerStart = true
            }
        }

        let imageRegion = NSRect(
            x: 0,
            y: 0,
            width: texture.width,
            height: texture.height
        )
        server?.publishFrameTexture(
            texture,
            on: commandBuffer,
            imageRegion: imageRegion,
            flipped: true
        )
        #endif
    }
}
