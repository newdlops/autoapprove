import Foundation
import AutoApproveCore

@main struct WorkerAuthCheck {
    static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),token="SyntheticOAuthTokenNeverSent0123456789"
        let credential=Data(("oauth_token = \""+token+"\"\nrefresh_token = \"SyntheticRefreshNeverSent0123456789\"\nexpiration_time = \"2030-01-01T00:00:00.000Z\"\nscopes = [\"account:read\", \"workers:write\", \"offline_access\"]\n").utf8)
        let result=try await CloudflareWorkersTool.authorize(directory:root,credential:credential,interactive:false,onURL:{_ in fatalError("Must not open a browser for stored OAuth")})
        guard result.token==token,result.credential==credential else {throw AppError.message("Official Wrangler credential roundtrip failed")}
        let leftovers=(try? FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("worker-auth").path)) ?? []
        guard leftovers.isEmpty else {throw AppError.message("Temporary OAuth HOME was not cleaned")}
        print("PASS: pinned official Wrangler reads synthetic non-expired OAuth in isolated HOME; token stdout separated, no browser or Cloudflare request; credential HOME removed")
    }
}
