// Ed25519 signing for in-app updates. Driven by scripts/update-keygen.sh and
// scripts/sign-update.sh; the private key lives in the login Keychain and
// only ever passes through stdin.
//
//   keygen                  → prints a new private key (base64)
//   pubkey                  ← private key on stdin, prints the public key
//   sign <zip> <version>    ← private key on stdin, prints the signature
//   verify <zip> <version> <sig-file> <pubkey>
//
// The signed message binds the version to the zip's SHA-256, so a genuine
// older zip can't be replayed as a newer version. Must match
// UpdateSignature.message(version:sha256Hex:) in the app.
import CryptoKit
import Foundation

func die(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

func sha256Hex(_ path: String) -> String {
    guard let h = FileHandle(forReadingAtPath: path) else { die("can't read \(path)") }
    var hasher = SHA256()
    while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func message(_ version: String, _ sha: String) -> Data {
    Data("Transcriberr update\n\(version)\n\(sha)\n".utf8)
}

func privateKeyFromStdin() -> Curve25519.Signing.PrivateKey {
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { die("bad private key on stdin") }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "keygen":
    print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
case "pubkey":
    print(privateKeyFromStdin().publicKey.rawRepresentation.base64EncodedString())
case "sign" where args.count == 3:
    let a = Array(args)
    let key = privateKeyFromStdin()
    guard let sig = try? key.signature(for: message(a[2], sha256Hex(a[1]))) else { die("signing failed") }
    print(sig.base64EncodedString())
case "verify" where args.count == 5:
    let a = Array(args)
    guard let sigText = try? String(contentsOfFile: a[3], encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let pubRaw = Data(base64Encoded: a[4]),
          let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw) else { die("bad input") }
    if pub.isValidSignature(sig, for: message(a[2], sha256Hex(a[1]))) { print("signature OK") } else { die("signature INVALID") }
default:
    die("usage: keygen | pubkey | sign <zip> <version> | verify <zip> <version> <sig> <pubkey>")
}
