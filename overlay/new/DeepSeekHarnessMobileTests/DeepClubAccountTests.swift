import Foundation
import Security
import XCTest
#if canImport(DeepSeekHarnessMobile)
@testable import DeepSeekHarnessMobile
#endif

final class DeepClubAccountTests: XCTestCase {
    private final class SavedCredential: @unchecked Sendable {
        // Accessed only under the credential gate, or after the dispatch group finishes.
        var token: String?
        var failure: Error?
    }

    func testSimulatorKeychainRoundTripWithoutUserCredentials() async throws {
        let account = "synthetic-keychain-probe-\(UUID().uuidString)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "net.deepclub.remote.account", kSecAttrAccount as String: account]
        var absent: CFTypeRef?
        let copyStatus = SecItemCopyMatching(query as CFDictionary, &absent)
        let deleteStatus = SecItemDelete(query as CFDictionary)
        print("DeepClubKeychainProbe SecItemCopyMatching OSStatus=\(copyStatus)")
        print("DeepClubKeychainProbe SecItemDelete OSStatus=\(deleteStatus)")
        XCTAssertEqual(copyStatus, errSecItemNotFound)
        XCTAssertEqual(deleteStatus, errSecItemNotFound)
        guard copyStatus == errSecItemNotFound, deleteStatus == errSecItemNotFound else { return }
        XCTAssertNil(try DeepClubKeychain.load(account))
        XCTAssertNoThrow(try DeepClubKeychain.delete(account))
        let payload = Data("DeepClub synthetic Keychain probe; not an account credential".utf8)
        defer { try? DeepClubKeychain.delete(account) }
        try DeepClubKeychain.save(payload, account: account)
        XCTAssertEqual(try DeepClubKeychain.load(account), payload)
        try DeepClubKeychain.delete(account)
        XCTAssertNil(try DeepClubKeychain.load(account))
        print("DeepClubKeychainProbe round_trip=passed; synthetic item removed")
        await MainActor.run {
            XCTAssertNil(DeepClubAccount.shared.session)
            XCTAssertNil(DeepClubAccount.shared.error, "Fresh logged-out startup must not have a Keychain error")
        }
    }

    func testLogoutSerializesWithAnInFlightCredentialSave() throws {
        let gate = DeepClubCredentialGate()
        gate.activate()
        let saved = SavedCredential()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                try gate.withActiveAccount {
                    saved.token = "synthetic-device-token"
                    entered.signal()
                    release.wait()
                }
            } catch { saved.failure = error; entered.signal() }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { try gate.invalidate { saved.token = nil } }
            catch { saved.failure = error }
        }
        release.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertNil(saved.failure)
        XCTAssertNil(saved.token)
        XCTAssertThrowsError(try gate.withActiveAccount { saved.token = "late-token" })
        XCTAssertNil(saved.token)
    }

    func testFailedCleanupDoesNotPermitCredentialWrites() throws {
        let gate = DeepClubCredentialGate()
        gate.activate()
        XCTAssertThrowsError(try gate.invalidate { throw DeepClubError.storage })
        var wrote = false
        XCTAssertThrowsError(try gate.withActiveAccount { wrote = true })
        XCTAssertFalse(wrote)
        // A fresh validated login may explicitly reopen the account scope.
        gate.activate()
        try gate.withActiveAccount { wrote = true }
        XCTAssertTrue(wrote)
    }

    func testCancelledConnectionCannotWriteAfterNewLogin() throws {
        let gate = DeepClubCredentialGate()
        gate.activate()
        let saved = SavedCredential()
        let finished = expectation(description: "cancelled save rejected")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try gate.withActiveAccount { saved.token = "late-token" }
                saved.failure = DeepClubError.invalidSession
            } catch is CancellationError {
                // The actor may run after a new login; task cancellation still wins.
            } catch { saved.failure = error }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        withExtendedLifetime(task) {}
        XCTAssertNil(saved.token)
        XCTAssertNil(saved.failure)
    }
}
