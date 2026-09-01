import Security
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: trust_signing_cert <certificate.der>\n".utf8))
    exit(1)
}

let path = CommandLine.arguments[1]
guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
    FileHandle.standardError.write(Data("cannot read certificate: \(path)\n".utf8))
    exit(1)
}
guard let cert = SecCertificateCreateWithData(nil, data as CFData) else {
    FileHandle.standardError.write(Data("cannot parse certificate\n".utf8))
    exit(1)
}

// kSecTrustSettingsResultTrustRoot (1) — trust this certificate as an anchor
// in the USER trust domain, so codesign accepts it as a valid identity
// without requiring admin rights.
let settings: [CFString: Any] = [
    "Policy" as CFString: SecPolicyCreateBasicX509(),
    "Result" as CFString: NSNumber(value: 1),
]

let status = SecTrustSettingsSetTrustSettings(cert, .user, settings as CFDictionary)
guard status == errSecSuccess else {
    FileHandle.standardError.write(Data("SecTrustSettingsSetTrustSettings failed: \(status)\n".utf8))
    exit(1)
}

print("user trust set for signing certificate")