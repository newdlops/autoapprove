import Foundation
import AutoApproveCore

@main struct WorkerPackageCheck {
    @MainActor static func main() async throws {
        guard Bundle.main.bundleURL.pathExtension=="app" else {throw AppError.message("Fixture must run in a relocated application bundle")}
        let fixture=WorkersFixture(),manager=fixture.manager()
        try await manager.authorize();_ = try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"a")
        guard fixture.uploads==1 else {throw AppError.message("Packaged Worker source could not be uploaded to synthetic API")}
        let url=Bundle.main.resourceURL!.appendingPathComponent("AutoApprove_AutoApproveCore.bundle/CloudflareRelay/relay.mjs")
        try FileManager.default.removeItem(at:url)
        do {_ = try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"a");throw AppError.message("Missing app resource must never use the build machine bundle")}
        catch {guard error.localizedDescription.contains("앱을 다시 설치") else {throw error}}
        print("PASS: relocated app uses its packaged Worker resource; missing resource fails safely without SwiftPM build-path fallback; synthetic API only")
    }
}
