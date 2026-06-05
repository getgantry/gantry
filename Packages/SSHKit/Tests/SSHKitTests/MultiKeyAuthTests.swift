import Testing
import Foundation
import Crypto
import NIOCore
import NIOEmbedded
@preconcurrency import NIOSSH
@testable import SSHKit

/// `MultiKeyAuthDelegate` sequencing: one key offered per attempt, failure
/// once exhausted, immediate failure when the server lacks publickey auth.
@Suite("MultiKeyAuthDelegate")
struct MultiKeyAuthTests {
    private func makeKeys(_ count: Int) -> [LoadedKey] {
        (0..<count).map { _ in .ed25519(Curve25519.Signing.PrivateKey()) }
    }

    @Test func offersEachKeyOnceThenFails() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let delegate = MultiKeyAuthDelegate(username: "deploy", keys: makeKeys(2))

        // Each rejected attempt makes NIOSSH ask again; the delegate must
        // produce one offer per key, in order.
        for _ in 0..<2 {
            let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
            delegate.nextAuthenticationType(
                availableMethods: .publicKey,
                nextChallengePromise: promise
            )
            let offer = try promise.futureResult.wait()
            #expect(offer?.username == "deploy")
        }

        // All keys consumed: the next request must fail, ending the attempt.
        let exhausted = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(
            availableMethods: .publicKey,
            nextChallengePromise: exhausted
        )
        #expect(throws: (any Error).self) {
            try exhausted.futureResult.wait()
        }
    }

    @Test func failsWhenServerDoesNotOfferPublickey() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let delegate = MultiKeyAuthDelegate(username: "deploy", keys: makeKeys(1))

        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(
            availableMethods: .password,
            nextChallengePromise: promise
        )
        #expect(throws: (any Error).self) {
            try promise.futureResult.wait()
        }
    }
}
