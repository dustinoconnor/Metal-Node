//
//  ExportDocuments.swift
//  MetalNode
//
//  Created by Codex on 3/13/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct TextExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .sourceCode, .json] }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
