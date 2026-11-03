import Foundation
import AutoApproveCore
@main struct DiagnosticPrivacyCheck {
 static func main()throws {
  let jwt="eyJ"+String(repeating:"A",count:350)+".payload.signature"
  let hidden=RemoteDiagnostics.text(jwt,limit:40)
  guard !hidden.contains("eyJ") else{throw AppError.message("Truncation exported a JWT prefix before redaction")}
  for raw in [#"{"access_token":"opaque-private-value"}"#,#"password="secret with spaces""#] {
   guard !RemoteDiagnostics.text(raw).contains("private-value"),!RemoteDiagnostics.text(raw).contains("secret with spaces") else{throw AppError.message("Quoted credential exported in diagnostic text")}
  }
  print("{\"verified\":true,\"redactionBeforeTruncation\":true,\"quotedCredentialsHidden\":true}")
 }
}
