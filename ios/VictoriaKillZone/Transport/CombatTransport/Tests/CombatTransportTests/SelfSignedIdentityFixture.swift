#if os(macOS)
import Foundation
import Security
@testable import CombatTransport

final class SelfSignedIdentityFixture: @unchecked Sendable, TransportIdentityProvider {
  let identity: sec_identity_t
  let pinnedPublicKey: Data

  private let directory: URL
  private var keychain: SecKeychain?

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("combat-transport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let keyURL = directory.appendingPathComponent("identity-key.pem")
    let certURL = directory.appendingPathComponent("identity-cert.pem")
    let p12URL = directory.appendingPathComponent("identity.p12")
    try Self.run(
      "/usr/bin/openssl",
      arguments: [
        "req", "-x509", "-newkey", "rsa:2048",
        "-keyout", keyURL.path,
        "-out", certURL.path,
        "-days", "1", "-nodes",
        "-subj", "/CN=vkz-combat-transport-test"
      ]
    )
    try Self.run(
      "/usr/bin/openssl",
      arguments: [
        "pkcs12", "-export",
        "-out", p12URL.path,
        "-inkey", keyURL.path,
        "-in", certURL.path,
        "-passout", "pass:transport-test"
      ]
    )

    let keychainURL = directory.appendingPathComponent("identity.keychain")
    var createdKeychain: SecKeychain?
    let keychainStatus = SecKeychainCreate(
      keychainURL.path,
      UInt32("transport-test".utf8.count),
      "transport-test",
      false,
      nil,
      &createdKeychain
    )
    guard keychainStatus == errSecSuccess, let createdKeychain else {
      throw FixtureError.securityStatus(keychainStatus)
    }
    keychain = createdKeychain

    let p12Data = try Data(contentsOf: p12URL)
    let options: [String: Any] = [
      kSecImportExportPassphrase as String: "transport-test",
      kSecImportExportKeychain as String: createdKeychain
    ]
    var imported: CFArray?
    let importStatus = SecPKCS12Import(
      p12Data as CFData,
      options as CFDictionary,
      &imported
    )
    guard importStatus == errSecSuccess,
          let entries = imported as? [[String: Any]],
          let entry = entries.first
    else {
      throw FixtureError.securityStatus(importStatus)
    }
    guard let secIdentity = Self.identity(
      from: entry[kSecImportItemIdentity as String]
    ) else {
      throw FixtureError.identityUnavailable
    }
    guard let createdIdentity = sec_identity_create(secIdentity) else {
      throw FixtureError.identityUnavailable
    }
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(secIdentity, &certificate) == errSecSuccess,
          let certificate,
          let publicKey = TransportSecurity.publicKeyBytes(of: certificate)
    else {
      throw FixtureError.identityUnavailable
    }
    identity = createdIdentity
    pinnedPublicKey = publicKey
  }

  deinit {
    if let keychain {
      SecKeychainDelete(keychain)
    }
    try? FileManager.default.removeItem(at: directory)
  }

  private static func run(_ executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw FixtureError.opensslFailed(process.terminationStatus)
    }
  }

  private static func identity(from value: Any?) -> SecIdentity? {
    guard let value,
          CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID()
    else {
      return nil
    }
    return dynamicCast(value, to: SecIdentity.self)
  }

  private static func dynamicCast<T, U>(_ value: T, to: U.Type) -> U? {
    value as? U
  }

  private enum FixtureError: Error {
    case opensslFailed(Int32)
    case securityStatus(OSStatus)
    case identityUnavailable
  }

  func localIdentity() -> sec_identity_t? {
    identity
  }
}
#endif
