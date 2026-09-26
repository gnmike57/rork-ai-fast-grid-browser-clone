import SwiftUI
import UniformTypeIdentifiers

/// Thin `FileDocument` wrapper so a captured session can be exported to Files
/// via SwiftUI's `.fileExporter`. The payload is the JSON of a
/// `SessionSnapshot`; the file itself is a plain `.json`.
nonisolated struct SessionFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
