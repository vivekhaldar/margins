import SwiftUI

/// Stand-in for `@State`. On recent SDKs `@State` is a macro whose plugin ships only with Xcode,
/// and Margins builds with the Command Line Tools alone, so view-local state lives in a tiny ObservableObject.
final class Local<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
