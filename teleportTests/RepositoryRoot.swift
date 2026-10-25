import Foundation

/// The checkout the tests were compiled from. Tests read the bundled Xray and the scripts from it
/// because the test runner's working directory is not the repository.
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
