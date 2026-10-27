import SwiftUI
import AppKit
import AutoApproveCore

@MainActor struct TunnelSettings: View {
    let engine: ApprovalEngine
    @StateObject private var updates=WindowViewUpdates()
    @State private var configuration=RemoteTunnelConfiguration()
    @State private var token=""
    @State private var port="8766"
    @State private var error:String?
    @State private var copied:String?
    @State private var busy=false
    @State private var attempted=false
    @State private var cloudflareDomain=""
    @State private var cloudflareSubdomain="aa"
    @State private var connectionTask:Task<Void,Never>?
    @State private var qrCodes=QRCodeImageCache()
    @FocusState private var focused:Field?
    private enum Field {case address,token}
    private var validPort:Bool {configuration.provider == .quick || configuration.provider.managedAddress || (UInt16(port).map {$0 > 0} ?? false)}
    private var addressError:String? {
        guard configuration.provider != .quick,attempted || !configuration.publicURL.isEmpty else {return nil}
        return (try? RemoteTunnelSetup.origin(configuration.publicURL)) == nil ? "공개 도메인을 입력하세요. 예: terminal.example.com" : nil
    }
    private var serviceURL:String {engine.tunnelStatus.localURL ?? "http://"+RemoteLoopback.host(requestedPort:UInt16(port) ?? configuration.port)+":"+port}
    private var subdomainError:String? {
        guard configuration.provider.managedAddress else {return nil}
        do {_ = try RemoteTunnelSetup.subdomain(cloudflareSubdomain);return nil} catch {return error.localizedDescription}
    }
    var body:some View {
        let status=engine.tunnelStatus
        VStack(alignment:.leading,spacing:10) {
            Label("다른 네트워크에서 접속",systemImage:"network").font(.headline)
            Text("다른 기기에서 이 Mac과 연결된 Mac의 터미널을 엽니다. 접속 링크와 QR은 본인 기기에만 공유하세요.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Picker("연결 방식",selection:$configuration.provider) {
                ForEach(RemoteTunnelProvider.allCases,id:\.self) {Text($0.title).tag($0)}
            }.disabled(busy || status.active || engine.cloudflareStatus.busy).accessibilityIdentifier("tunnel-provider")
            if configuration.provider == .quick {
                Text("‘임시 주소 만들기’를 누르면 연결 도구 설치와 웹 접속을 자동으로 준비합니다. 계정이나 도메인은 필요 없습니다.")
                    .font(.callout).fixedSize(horizontal:false,vertical:true)
                Text("다시 만들면 주소가 바뀝니다. 임시 주소는 화면을 순서대로 조회하며 고정 도메인은 실시간 스트림을 사용합니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            } else if configuration.provider.managedAddress {
                CloudflareApprovalSteps(state:engine.cloudflareStatus,tunnelActive:status.active,approvalURL:engine.cloudflareApprovalURL,
                                        address:engine.cloudflareAddress(domainID:cloudflareDomain,subdomain:cloudflareSubdomain,provider:configuration.provider),domainID:$cloudflareDomain,
                                        subdomain:$cloudflareSubdomain,subdomainError:subdomainError,busy:busy,https:configuration.provider == .https,
                                        approve:approveCloudflare,reload:{Task {try? await engine.loadCloudflareDomains(provider:configuration.provider)}},connect:connect)
            } else {
                if configuration.provider == .named {
                    Text("1. Cloudflare에서 터널 만들기").font(.callout.weight(.medium))
                    Text("Networking → Tunnels에서 터널을 만들고 macOS 설치 명령을 복사하세요.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    HStack(spacing:12) {
                        Link("Cloudflare 터널 열기",destination:RemoteTunnelSetup.dashboardURL)
                        Link("설정 안내",destination:RemoteTunnelSetup.guideURL)
                    }.font(.callout)
                    Text("2. 이 Mac 연결하기").font(.callout.weight(.medium)).padding(.top,4)
                    HStack {
                        SecureField("설치 명령 또는 터널 토큰",text:$token)
                            .textFieldStyle(.roundedBorder).focused($focused,equals:.token)
                            .accessibilityLabel("Cloudflare 설치 명령 또는 터널 토큰").accessibilityIdentifier("tunnel-token")
                            .onSubmit {connect()}.disabled(busy || status.active)
                        Button("붙여넣기") {token=NSPasteboard.general.string(forType:.string) ?? "";error=nil}
                            .disabled(busy || status.active).help("복사한 설치 명령에서 토큰만 읽어 연결합니다.")
                    }
                    Text("명령을 통째로 붙여넣을 수 있습니다. 토큰은 Mac 키체인에 저장하며 저장한 토큰을 쓰려면 비워 두세요.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                } else {
                    Text("사용 중인 로컬 터널의 서비스 주소를 아래 값으로 지정하고 공개 도메인을 입력하세요. 터널 프로그램은 별도로 실행합니다.")
                        .font(.callout).fixedSize(horizontal:false,vertical:true)
                }
                VStack(alignment:.leading,spacing:4) {
                    Text("공개 도메인").font(.callout.weight(.medium))
                    TextField("terminal.example.com",text:$configuration.publicURL)
                        .textFieldStyle(.roundedBorder).focused($focused,equals:.address)
                        .accessibilityLabel("터널의 공개 도메인").accessibilityIdentifier("tunnel-address")
                        .onSubmit {connect()}.disabled(busy || status.active)
                    if let addressError {Text(addressError).font(.caption).foregroundStyle(.red)}
                    else {Text("도메인만 입력하면 HTTPS 주소로 연결합니다.").font(.caption).foregroundStyle(.secondary)}
                }
                if configuration.provider == .named {
                    Text("3. Cloudflare에 공개 경로 추가").font(.callout.weight(.medium)).padding(.top,4)
                    Text("아래 연결 버튼을 누른 뒤 Cloudflare에서 터널의 Routes → Published application에 위 도메인과 아래 서비스 주소를 지정하세요.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                ViewThatFits(in:.horizontal) {
                    HStack {Text(serviceURL).font(.system(.callout,design:.monospaced)).textSelection(.enabled);copyServiceButton}
                    VStack(alignment:.leading,spacing:6) {Text(serviceURL).font(.system(.callout,design:.monospaced)).textSelection(.enabled);copyServiceButton}
                }.accessibilityElement(children:.contain)
            }
            TunnelPINSettings(configured:engine.tunnelPINConfigured,save:{try await engine.setTunnelPIN($0)},clear:{try engine.clearTunnelPIN()})
            HStack {
                if !status.active {
                    Button(busy ? "준비 중…" : status.phase == "failed" ? "다시 연결" : configuration.provider.managedAddress ? "연결" : configuration.provider == .quick ? "임시 주소 만들기" : configuration.provider == .named ? "고정 도메인 연결" : "터널 연결 확인") {connect()}
                        .buttonStyle(.bordered).disabled(busy || !validPort || engine.cloudflareStatus.busy || (configuration.provider.managedAddress && (!engine.cloudflareStatus.authorized || cloudflareDomain.isEmpty || subdomainError != nil)))
                        .accessibilityIdentifier("tunnel-connect")
                }
                if status.phase == "routeRequired" {
                    Button("공개 주소 확인") {engine.checkTunnelAddress()}.accessibilityIdentifier("tunnel-verify")
                }
                if busy || status.phase != "off" || engine.cloudflareStatus.busy {
                    Button(status.ready ? "연결 종료" : status.phase == "failed" ? "닫기" : "취소") {cancel()}
                        .accessibilityIdentifier("tunnel-stop")
                }
                if busy || engine.cloudflareStatus.busy || status.active && !status.ready && status.phase != "routeRequired" {
                    ProgressView().controlSize(.small).accessibilityLabel("터널 연결 준비 중")
                }
            }.padding(.top,4)
            if status.phase != "off" {
                Text(status.detail).font(.callout).foregroundStyle(status.phase == "failed" ? .red : .secondary)
                    .textSelection(.enabled).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("tunnel-status")
                TunnelConnectionQuality(quality:status.quality,enabled:status.ready,measure:{await engine.measureTunnelConnection()})
            }
            if ["failed","reconnecting"].contains(status.phase),configuration.provider.usesCloudflared {
                Button("HTTPS (443)로 연결") {cancel();configuration.provider = .https;error=nil}
                    .disabled(busy || engine.cloudflareStatus.busy).accessibilityIdentifier("tunnel-use-https")
            }
            if let link=engine.tunnelShareURL,let address=status.publicURL {
                ViewThatFits(in:.horizontal) {
                    HStack(alignment:.top,spacing:16) {qr(link);share(link,address:address)}
                    VStack(alignment:.leading,spacing:10) {qr(link);share(link,address:address)}
                }
                if !engine.tunnelPINConfigured {DisclosureGroup("접속 키 직접 입력") {
                    if let key=engine.tunnelAccessKey {
                        Text(key).font(.system(.caption,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        Button(copied == "key" ? "복사됨" : "접속 키 복사") {copy(key,kind:"key")}
                    }
                }.font(.caption)}
            }
            if let error {Label(error,systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
            DisclosureGroup("연결 세부 설정") {
                VStack(alignment:.leading,spacing:8) {
                    if !configuration.provider.managedAddress && configuration.provider != .quick { HStack {
                        Text("서비스 포트");TextField("8766",text:$port).textFieldStyle(.roundedBorder).frame(width:90)
                            .accessibilityLabel("터널 서비스 포트").disabled(busy || status.active)
                        if !validPort {Text("1~65535").font(.caption).foregroundStyle(.red)}
                    }} else {Text("서비스 포트는 자동으로 배정합니다.").font(.caption).foregroundStyle(.secondary)}
                    if configuration.provider.usesCloudflared {
                        Text(engine.tunnelToolPath != nil || !configuration.executable.isEmpty ? "Cloudflare 연결 도구 준비됨" : "연결을 시작할 때 Cloudflare 도구를 자동으로 설치합니다.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        HStack {
                            Button("cloudflared 파일 선택") {chooseExecutable()}.disabled(busy || status.active)
                            if !configuration.executable.isEmpty {Button("기본 도구 사용") {configuration.executable=""}.disabled(busy || status.active)}
                        }
                        if !configuration.executable.isEmpty {Text(configuration.executable).font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
                    }
                    Text("웹 접속과 연결 도구는 시작할 때 준비합니다. 켜 둔 연결은 앱 재실행 후 복원하며 새 접속 키를 발급합니다. 연결을 종료하면 외부 접속을 해제합니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }.padding(.top,4)
            }.font(.callout)
        }.frame(maxWidth:.infinity,alignment:.leading)
            .windowUpdates(updates,sources:[engine.objectWillChange])
            .onAppear {
                do{try engine.loadTunnelPIN()}catch{self.error=error.localizedDescription}
                configuration=engine.tunnelConfiguration
                if !engine.hasTunnelConfiguration {configuration.provider = .https}
                if configuration.provider.managedAddress,let host=URLComponents(string:configuration.publicURL)?.host,
                   let first=host.split(separator:".").first,let saved=try? RemoteTunnelSetup.subdomain(String(first)) {cloudflareSubdomain=saved}
                port=String(configuration.port)
            }
            .onChange(of:configuration.provider) {previous,_ in
                attempted=false;error=nil
                if engine.tunnelStatus.phase == "failed",engine.tunnelStatus.provider == previous {try? engine.stopTunnel()}
            }
            .onChange(of:engine.cloudflareStatus.domains) {_,domains in
                if !domains.contains(where:{$0.id == cloudflareDomain}) {
                    cloudflareDomain=domains.first(where:{RemoteTunnelSetup.subdomain(from:configuration.publicURL,domain:$0.name) != nil})?.id ?? (domains.count == 1 ? domains[0].id : "")
                }
            }
            .task(id:configuration.provider) { [provider=configuration.provider] in
                if provider.managedAddress && !Task.isCancelled {try? await engine.loadCloudflareDomains(provider:provider)}
            }
            .task(id:copied) {if copied != nil {try? await Task.sleep(for:.seconds(2));if !Task.isCancelled {copied=nil}}}
    }
    private var copyServiceButton:some View {Button(copied == "service" ? "복사됨" : "서비스 주소 복사") {copy(serviceURL,kind:"service")}.disabled(!validPort)}
    private func copy(_ value:String,kind:String) {NSPasteboard.general.clearContents();NSPasteboard.general.setString(value,forType:.string);copied=kind}
    private func qr(_ link:URL)->some View {
        Group {if let image=qrCodes.image(for:link.absoluteString) {
            Image(nsImage:image).interpolation(.none).resizable().frame(width:116,height:116).padding(8).background(.white)
                .clipShape(RoundedRectangle(cornerRadius:8)).accessibilityLabel(engine.tunnelPINConfigured ? "PIN으로 로그인하는 접속 주소 QR 코드":"인증 키가 포함된 외부 접속 QR 코드")
        }}
    }
    private func share(_ link:URL,address:String)->some View {
        VStack(alignment:.leading,spacing:8) {
            Text(address).font(.system(.callout,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            ShareLink(item:link) {Label("접속 링크 공유",systemImage:"square.and.arrow.up")}
            HStack {Button(copied == "link" ? "복사됨" : "접속 링크 복사") {copy(link.absoluteString,kind:"link")};Link("웹에서 열기",destination:link)}
            Text(engine.tunnelPINConfigured ? "이 주소를 열고 지정한 PIN을 입력하세요. 브라우저 접속은 최대 8시간 유지됩니다.":"QR과 링크에 접속 키가 포함됩니다. 브라우저 접속은 최대 8시간 유지됩니다.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func connect() {
        guard !busy,!engine.tunnelStatus.active else {return}
        attempted=true;error=nil
        guard configuration.provider.managedAddress || addressError == nil else {focused = .address;return}
        if configuration.provider.managedAddress {
            guard let label=try? RemoteTunnelSetup.subdomain(cloudflareSubdomain) else {return}
            cloudflareSubdomain=label
        }
        let selectedPort:UInt16? = configuration.provider == .quick || configuration.provider.managedAddress ? 8766 : UInt16(port)
        guard let number=selectedPort,number > 0 else {return}
        configuration.port=number;busy=true
        let secret=token;token=""
        connectionTask=Task {
            do {
                if configuration.provider.managedAddress {try await engine.connectCloudflare(domainID:cloudflareDomain,subdomain:cloudflareSubdomain,executable:configuration.executable,provider:configuration.provider)}
                else {try await engine.connectTunnel(configuration,token:secret)}
            }
            catch is CancellationError {} catch {
                if engine.tunnelStatus.phase != "failed" && engine.cloudflareStatus.phase != "failed" {self.error=error.localizedDescription}
                if configuration.provider == .named {focused = .token}
            }
            busy=false;connectionTask=nil
        }
    }
    private func cancel() {
        connectionTask?.cancel()
        engine.cancelCloudflareSetup()
        do {if engine.tunnelStatus.phase != "off" {try engine.stopTunnel()};error=nil} catch {self.error=error.localizedDescription}
    }
    private func approveCloudflare() {
        guard !busy,!engine.cloudflareStatus.busy else {return}
        busy=true;error=nil
        connectionTask=Task {
            do {try await engine.authorizeCloudflare(executable:configuration.executable,provider:configuration.provider)}
            catch is CancellationError {} catch {if engine.cloudflareStatus.phase != "failed" {self.error=error.localizedDescription}}
            busy=false;connectionTask=nil
        }
    }
    private func chooseExecutable() {
        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.message="cloudflared 실행 파일을 선택하세요."
        if panel.runModal() == .OK,let url=panel.url {
            if FileManager.default.isExecutableFile(atPath:url.path) {configuration.executable=url.path;error=nil}
            else {error="실행 가능한 cloudflared 파일을 선택해주세요."}
        }
    }
}
