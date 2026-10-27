import Foundation
import CryptoKit

/// Sensitive account messages stay encrypted through LAN and relay hops.
/// This does not authenticate the HTML origin on an actively compromised LAN.
public final class AgentAccountCrypto {
    public let id=UUID().uuidString
    private let key=Curve25519.KeyAgreement.PrivateKey()
    public init() {}
    public var publicKey:String {key.publicKey.rawRepresentation.base64EncodedString()}
    public struct Request {
        public let object:JSONObject
        fileprivate let key:SymmetricKey,aad:Data
    }
    public func open(_ envelope:JSONObject,node:String) throws -> Request {
        guard envelope["version"] as? Int==1,envelope["keyID"] as? String==id,
              let request=envelope["request"] as? String,UUID(uuidString:request) != nil,
              let raw=envelope["publicKey"] as? String,let bytes=Data(base64Encoded:raw),bytes.count==32,
              let payload=envelope["payload"] as? String,payload.count<24000,
              let data=Data(base64Encoded:payload),(28...16000).contains(data.count) else {throw RemoteHTTPError(409,"로그인 보안 연결이 바뀌었습니다. 창을 다시 열어주세요.")}
        let aad=Data("AutoApprove accounts v1:\(node):\(id):\(request)".utf8)
        do {
            let secret=try key.sharedSecretFromKeyAgreement(with:Curve25519.KeyAgreement.PublicKey(rawRepresentation:bytes))
            let derived=secret.hkdfDerivedSymmetricKey(using:SHA256.self,salt:Data(),sharedInfo:aad,outputByteCount:32)
            let plain=try ChaChaPoly.open(ChaChaPoly.SealedBox(combined:data),using:derived,authenticating:aad)
            guard let object=try JSONSerialization.jsonObject(with:plain) as? JSONObject else {throw RemoteHTTPError(400,"로그인 요청 형식을 확인해주세요.")}
            return Request(object:object,key:derived,aad:aad)
        } catch let error as RemoteHTTPError {throw error}
        catch {throw RemoteHTTPError(400,"로그인 암호화 요청을 확인하지 못했습니다.")}
    }
    public func seal(_ object:JSONObject,for request:Request) throws -> JSONObject {
        let data=try JSONSerialization.data(withJSONObject:object)
        let aad=request.aad+Data(".reply".utf8)
        return ["version":1,"payload":try ChaChaPoly.seal(data,using:request.key,authenticating:aad).combined.base64EncodedString()]
    }
}
