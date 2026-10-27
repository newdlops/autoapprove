import Foundation

public struct PublishedUpdateReply:Sendable {
    public var status:Int
    public var body:Data
    public var contentRange:String?
    public init(status:Int,body:Data,contentRange:String? = nil) {self.status=status;self.body=body;self.contentRange=contentRange}
}

public struct PublishedUpdateServices:Sendable {
    public var exchange:@Sendable(URLRequest,Int) async throws -> PublishedUpdateReply
    public init(exchange:@escaping @Sendable(URLRequest,Int) async throws -> PublishedUpdateReply) {self.exchange=exchange}
    public static let live=Self {request,limit in
        let configuration=URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies=false;configuration.timeoutIntervalForRequest=15;configuration.timeoutIntervalForResource=30
        let session=URLSession(configuration:configuration,delegate:PublishedUpdateRedirectPolicy(),delegateQueue:nil)
        defer {session.invalidateAndCancel()}
        let (bytes,response)=try await session.bytes(for:request)
        guard response.expectedContentLength <= limit else {throw AppError.message("업데이트 응답이 너무 큽니다.")}
        var data=Data();data.reserveCapacity(min(limit,262144))
        for try await byte in bytes {guard data.count<limit else {throw AppError.message("업데이트 응답이 너무 큽니다.")};data.append(byte)}
        let http=response as? HTTPURLResponse
        return PublishedUpdateReply(status:http?.statusCode ?? 0,body:data,contentRange:http?.value(forHTTPHeaderField:"Content-Range"))
    }
}

final class PublishedUpdateRedirectPolicy:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    static func allowed(_ url:URL)->Bool {
        guard let c=URLComponents(url:url,resolvingAgainstBaseURL:false),c.scheme=="https",c.user==nil,c.password==nil,
              c.port==nil || c.port==443,c.fragment==nil else {return false}
        switch c.host {
        case "api.github.com":return c.path=="/repos/newdlops/autoapprove/releases/latest"
        case "github.com":return c.path.hasPrefix("/newdlops/autoapprove/releases/download/")
        case "release-assets.githubusercontent.com","objects.githubusercontent.com","github-releases.githubusercontent.com":return true
        default:return false
        }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {
        guard let url=request.url,Self.allowed(url),request.httpMethod=="GET" else {completionHandler(nil);return}
        var safe=request;safe.setValue(nil,forHTTPHeaderField:"Authorization");safe.setValue(nil,forHTTPHeaderField:"Cookie");completionHandler(safe)
    }
}

public struct PublishedReleaseOffer:Sendable,Equatable {
    public static let sourceID="d9903b06-54ae-4d8c-bc13-2132e02025cb"
    public var manifest:LANUpdateManifest
    public var url:URL
}

public struct PublishedReleaseRecord:Sendable {
    public var version:String
    public var offer:PublishedReleaseOffer?
    public static func decode(_ data:Data) throws -> Self {
        func invalid()->AppError {.message("정식 AutoApprove 릴리스 정보를 확인하지 못했습니다.")}
        guard let object=try JSONSerialization.jsonObject(with:data) as? JSONObject,
              object["draft"] as? Bool==false,object["prerelease"] as? Bool==false,
              let tag=object["tag_name"] as? String,tag.hasPrefix("v"),
              let assets=object["assets"] as? [JSONObject] else {throw invalid()}
        let version=String(tag.dropFirst())
        guard RemoteWebVersion(version:version,build:1).isCompatible else {throw invalid()}
        let prefix="AutoApprove-\(version)-build",suffix="-macOS-\(LANUpdateManifest.architecture).zip"
        var offers:[PublishedReleaseOffer]=[]
        for asset in assets {
            guard let name=asset["name"] as? String,name.hasPrefix(prefix),name.hasSuffix(suffix) else {continue}
            let text=String(name.dropFirst(prefix.count).dropLast(suffix.count))
            guard !text.isEmpty,text.utf8.allSatisfy({(48...57).contains($0)}),let build=Int(text),String(build)==text,
                  let size=asset["size"] as? Int,let digest=asset["digest"] as? String,digest.hasPrefix("sha256:"),
                  let address=asset["browser_download_url"] as? String,
                  address=="https://github.com/newdlops/autoapprove/releases/download/\(tag)/\(name)",let url=URL(string:address) else {throw invalid()}
            let manifest=LANUpdateManifest(nodeID:PublishedReleaseOffer.sourceID,release:RemoteWebVersion(version:version,build:build),size:size,sha256:String(digest.dropFirst(7)))
            try manifest.validate(nodeID:PublishedReleaseOffer.sourceID,newerThan:RemoteWebVersion(version:"0.0.0",build:0))
            offers.append(PublishedReleaseOffer(manifest:manifest,url:url))
        }
        guard offers.count<=1 else {throw invalid()}
        return Self(version:version,offer:offers.first)
    }
}

public struct PublishedUpdateStatus:Codable,Sendable {
    public var phase="idle"
    public var detail="정식 최신 버전을 확인할 수 있습니다."
    public var latestVersion:String?
    public var latest:RemoteWebVersion?
    public var checkedAt:Date?
    public var host:RemoteWebVersion?
    public var update:LANUpdateStatus?
    public var canSync=false
    public init() {}
}

@MainActor public final class PublishedUpdates {
    public private(set) var status=PublishedUpdateStatus()
    public private(set) var record:PublishedReleaseRecord?
    private let services:PublishedUpdateServices
    private var task:Task<Void,Never>?
    private var epoch=UUID()
    public init(services:PublishedUpdateServices = .live) {self.services=services}
    public func stop() {epoch=UUID();task?.cancel();task=nil;if status.phase=="checking" {status.phase="idle";status.detail="버전 확인을 중지했습니다."}}
    public func check() async {
        if let task {await task.value;return}
        if let checked=status.checkedAt,(0..<60).contains(Date().timeIntervalSince(checked)) {return}
        let epoch=self.epoch,services=self.services
        status.phase="checking";status.detail="정식 최신 버전을 확인하고 있습니다."
        let work=Task { [weak self] in
            do {
                var request=URLRequest(url:URL(string:"https://api.github.com/repos/newdlops/autoapprove/releases/latest")!)
                request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
                request.setValue("AutoApprove-Update",forHTTPHeaderField:"User-Agent");request.timeoutInterval=15
                let reply=try await services.exchange(request,2_000_000)
                guard reply.status==200 else {throw AppError.message("정식 릴리스 서버가 응답하지 않습니다.")}
                let record=try PublishedReleaseRecord.decode(reply.body)
                guard let self,self.epoch==epoch,!Task.isCancelled else {return}
                self.record=record;self.status.phase="ready";self.status.latestVersion=record.version;self.status.latest=record.offer?.manifest.release
                self.status.detail="정식 릴리스를 확인했습니다.";self.status.checkedAt=Date();self.task=nil
            } catch {
                guard let self,self.epoch==epoch,!Task.isCancelled else {return}
                self.record=nil;self.status.phase="failed";self.status.detail="최신 버전을 확인하지 못했습니다. 잠시 후 다시 시도해주세요."
                self.status.latest=nil;self.status.latestVersion=nil;self.status.checkedAt=Date();self.task=nil
            }
        }
        task=work;await work.value
    }
    public func read(_ path:String,offer:PublishedReleaseOffer) async throws -> RemoteHTTPResponse {
        guard let query=URLComponents(string:"http://update.invalid"+path),query.path=="/api/update/chunk",
              query.queryItems?.first(where:{$0.name=="sha256"})?.value==offer.manifest.sha256,
              let text=query.queryItems?.first(where:{$0.name=="offset"})?.value,let offset=Int(text),offset>=0,
              offset<offer.manifest.size,offset.isMultiple(of:LANUpdateManifest.chunkSize) else {throw RemoteHTTPError(400,"업데이트 위치가 올바르지 않습니다.")}
        let end=min(offer.manifest.size,offset+LANUpdateManifest.chunkSize)-1
        var request=URLRequest(url:offer.url);request.timeoutInterval=15
        request.setValue("bytes=\(offset)-\(end)",forHTTPHeaderField:"Range");request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
        let response=try await services.exchange(request,end-offset+1)
        guard response.status==206,response.contentRange=="bytes \(offset)-\(end)/\(offer.manifest.size)",response.body.count==end-offset+1 else {
            throw RemoteHTTPError(503,"업데이트 전송이 끊겼습니다. 받은 위치부터 다시 확인합니다.")
        }
        return RemoteHTTPResponse(body:response.body,contentType:"application/zip")
    }
}
