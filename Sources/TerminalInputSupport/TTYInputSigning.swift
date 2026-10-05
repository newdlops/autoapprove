import Foundation
import Security
import CryptoKit

public enum TTYInputSigning {
    public static func requirement(publisherSHA1: String, peerIdentifier: String) throws -> String {
        guard publisherSHA1.utf8.count == 40, publisherSHA1.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              [TTYInputConfiguration.appIdentifier, TTYInputConfiguration.cliIdentifier, TTYInputConfiguration.helperIdentifier].contains(peerIdentifier) else {
            throw NSError(domain: "AutoApprove.TerminalInput.Signing", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "입력 서비스의 게시자 서명을 확인하지 못했습니다."])
        }
        return "identifier \"\(peerIdentifier)\" and certificate leaf = H\"\(publisherSHA1)\""
    }
    public static func peerRequirement(ownIdentifier: String, peerIdentifier: String) throws -> String {
        try peerRequirements(ownIdentifiers: [ownIdentifier], peerIdentifiers: [peerIdentifier])
    }
    public static func peerRequirements(ownIdentifiers: [String], peerIdentifiers: [String]) throws -> String {
        let allowed = [TTYInputConfiguration.appIdentifier, TTYInputConfiguration.cliIdentifier, TTYInputConfiguration.helperIdentifier]
        guard !ownIdentifiers.isEmpty, !peerIdentifiers.isEmpty,
              ownIdentifiers.allSatisfy(allowed.contains), peerIdentifiers.allSatisfy(allowed.contains) else {
            throw NSError(domain: "AutoApprove.TerminalInput.Signing", code: 1)
        }
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let ownIdentifier = values[kSecCodeInfoIdentifier as String] as? String,
              ownIdentifiers.contains(ownIdentifier),
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else {
            throw NSError(domain: "AutoApprove.TerminalInput.Signing", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "동일한 게시자 서명이 있는 AutoApprove 설치본이 필요합니다."])
        }
        let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        let peers = try peerIdentifiers.map { try requirement(publisherSHA1: fingerprint, peerIdentifier: $0) }
        return peers.count == 1 ? peers[0] : peers.map { "(" + $0 + ")" }.joined(separator: " or ")
    }
}
