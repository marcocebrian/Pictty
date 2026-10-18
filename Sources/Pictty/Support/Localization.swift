import Foundation

/// A user-facing string in the user's language. Keys are the English text; translations live
/// in `Resources/<lang>.lproj/Localizable.strings`. SwiftUI `Text("literal")` looks the same
/// table up by itself; this is for strings built in code.
func L(_ english: String) -> String {
    NSLocalizedString(english, comment: "")
}

/// `L` with `String(format:)` arguments, e.g. `L("Showing %d of 2", n)`.
func L(_ english: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(english, comment: ""), arguments: args)
}
