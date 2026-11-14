import Foundation
import Testing
@testable import AppCore

@MainActor
@Test func libraryAddsRenamesReplacesAndDeletes() throws {
    let store = InMemorySecretStore()
    let library = SecretsLibrary(store: store)
    #expect(library.names.isEmpty)

    #expect(library.add(name: " api-token ", value: "v1"))
    #expect(library.names == ["api-token"])
    #expect(!library.add(name: "api-token", value: "v2"))
    #expect(library.lastError?.contains("api-token") == true)
    #expect(try store.value(for: "api-token") == "v1")

    #expect(library.save(name: "api-token", value: "v2"))
    #expect(try store.value(for: "api-token") == "v2")

    #expect(library.rename("api-token", to: "token"))
    #expect(library.names == ["token"])
    #expect(try store.value(for: "token") == "v2")

    #expect(library.delete(["token"]))
    #expect(library.names.isEmpty)
}

@MainActor
@Test func libraryRejectsBadInput() {
    let library = SecretsLibrary(store: InMemorySecretStore(["a": "1", "b": "2"]))
    #expect(!library.add(name: "bad name", value: "x"))
    #expect(!library.add(name: "ok", value: ""))
    #expect(!library.rename("a", to: "b"))
    #expect(!library.rename("a", to: "-x"))
    #expect(library.rename("a", to: "a"))
    #expect(library.names == ["a", "b"])
}

@MainActor
@Test func libraryErrorsNeverHoldValues() {
    let value = "do-not-print-me"
    let library = SecretsLibrary(store: InMemorySecretStore(["a": value]))
    _ = library.add(name: "a", value: value)
    #expect(library.lastError != nil)
    #expect(library.lastError?.contains(value) == false)
}
