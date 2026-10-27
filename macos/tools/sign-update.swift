// Ed25519 keys and signatures for macOS update archives.
//
//   swift sign-update.swift generate <private-key-file>   # writes the key, prints the public key
//   swift sign-update.swift public <private-key-file>     # prints the public key
//   swift sign-update.swift sign <private-key-file> <msg> # prints a base64 signature of <msg>
//
// The app verifies "<version>:<arch>:<sha256 of zip>" against the public key that
// build.sh embeds (UPDATE_PUBLIC_KEY), so only holders of the private key can ship updates.
import CryptoKit
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("Could not read private key from \(path)")
    }
    return key
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: sign-update.swift generate|public|sign <private-key-file> [message]") }

switch args[1] {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    guard !FileManager.default.fileExists(atPath: args[2]) else { fail("\(args[2]) already exists") }
    FileManager.default.createFile(atPath: args[2], contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey(args[2]).publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count >= 4 else { fail("sign needs a message") }
    let sig = try! loadKey(args[2]).signature(for: Data(args[3].utf8))
    print(sig.base64EncodedString())
default:
    fail("unknown command \(args[1])")
}
