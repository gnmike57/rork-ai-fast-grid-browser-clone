import SwiftUI
import UniformTypeIdentifiers

/// Thin `FileDocument` wrapper so the Results screen can export attempts to
/// Files as CSV or JSON via SwiftUI's `.fileExporter`. The content type is
/// picked at export time, so both are declared as supported.
nonisolated struct ResultsExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .json] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText, .json] }

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
