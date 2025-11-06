import SwiftUI
import UniformTypeIdentifiers

struct SQLiteDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [UTType(filenameExtension: "sqlite") ?? .data]
    }

    static var writableContentTypes: [UTType] {
        [UTType(filenameExtension: "sqlite") ?? .data]
    }

    var data: Data
    var fileName: String

    init(data: Data, fileName: String) {
        self.data = data
        self.fileName = fileName
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = contents
        self.fileName = configuration.file.filename ?? "FastingApp.sqlite"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = fileName
        return wrapper
    }
}
