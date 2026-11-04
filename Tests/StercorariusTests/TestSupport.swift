import Foundation

/// A new empty directory under the temporary directory; the caller removes it.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "stercorarius-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes `text` as UTF-8 to the file `name` inside `directory`.
func writeFile(_ text: String, named name: String, in directory: URL) throws {
    try Data(text.utf8).write(to: directory.appending(path: name))
}
