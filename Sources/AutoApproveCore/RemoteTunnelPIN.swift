import Foundation
import Security
import CLocalDashboard

public struct RemoteTunnelPIN:Codable,Sendable {
    private let version:Int,salt:Data,digest:Data
    public static func valid(_ pin:String)->Bool {(6...12).contains(pin.utf8.count) && pin.utf8.allSatisfy { $0>=48 && $0<=57 }}
    public static func create(_ pin:String) throws -> Self {
        guard valid(pin) else {throw AppError.message("PIN은 숫자 6~12자리로 지정해주세요.")}
        var salt=Data(count:16)
        let status=salt.withUnsafeMutableBytes {SecRandomCopyBytes(kSecRandomDefault,16,$0.baseAddress!)}
        guard status==errSecSuccess else {throw AppError.message("접속 PIN을 준비하지 못했습니다. 다시 시도해주세요.")}
        return Self(version:1,salt:salt,digest:try derive(pin,salt:salt))
    }
    public static func decode(_ data:Data) throws -> Self {
        guard data.count<=1024,let value=try? JSONDecoder().decode(Self.self,from:data),value.version==1,value.salt.count==16,value.digest.count==32 else {throw AppError.message("저장된 접속 PIN을 읽지 못했습니다. PIN을 다시 설정해주세요.")};return value
    }
    public func matches(_ pin:String)->Bool {
        guard version==1,salt.count==16,digest.count==32,Self.valid(pin),let candidate=try? Self.derive(pin,salt:salt) else {return false}
        return zip(candidate,digest).reduce(UInt8(0)) {$0 | ($1.0 ^ $1.1)}==0
    }
    private static func derive(_ pin:String,salt:Data) throws -> Data {
        let bytes=Array(pin.utf8);var digest=Data(count:32)
        let status=bytes.withUnsafeBytes {pin in salt.withUnsafeBytes {salt in digest.withUnsafeMutableBytes {digest in
            aa_derive_tunnel_pin(pin.baseAddress,UInt(bytes.count),salt.baseAddress,digest.baseAddress)
        }}}
        guard status==0 else {throw AppError.message("접속 PIN을 보호하지 못했습니다. 다시 시도해주세요.")};return digest
    }
}
