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
    @State private var busy=false
    @State private var installing=false
    @State private var qrCodes=QRCodeImageCache()
    private var validPort:Bool { UInt16(port).map { $0 > 0 } ?? false }
    var body: some View {
        let status=engine.tunnelStatus
        VStack(alignment:.leading,spacing:10) {
            Label("다른 네트워크에서 접속",systemImage:"network").font(.headline)
            Text("외부 HTTPS 주소에서 이 Mac과 연결된 Mac의 터미널을 엽니다. 접속 링크와 키를 가진 사람은 화면과 입력을 제어할 수 있으므로 본인 기기에만 공유하세요.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Picker("연결 방식",selection:$configuration.provider) {
                ForEach(RemoteTunnelProvider.allCases,id:\.self) { Text($0.title).tag($0) }
            }.disabled(busy || status.active)
            if configuration.provider != .quick {
                TextField("공개 HTTPS 주소 · https://terminal.example.com",text:$configuration.publicURL)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("터널의 공개 HTTPS 주소")
                    .disabled(busy || status.active)
                if configuration.provider == .named {
                    SecureField("Cloudflare 터널 토큰 · 저장한 토큰은 생략",text:$token)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Cloudflare 터널 토큰")
                        .disabled(busy || status.active)
                    Text("Cloudflare에서 터널과 공개 도메인을 만들고 아래 서비스 URL을 지정하세요. 토큰은 이 Mac의 키체인에 저장합니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Link("Cloudflare 설정 안내",destination:URL(string:"https://developers.cloudflare.com/tunnel/get-started/")!)
                } else {
                    Text("사용 중인 로컬 터널의 서비스 URL을 아래 주소로 지정하고 공개 HTTPS 주소를 입력하세요. 터널 도구는 별도로 실행합니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Text("서비스 URL: http://127.0.0.1:\(port)").font(.system(.callout,design:.monospaced))
                    .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            } else {
                Text("계정·도메인 없이 임시 주소를 만듭니다. 주소는 다시 연결할 때 바뀝니다. 임시 터널에서는 화면을 순서대로 조회하며 고정 도메인에서 실시간 스트림을 사용할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            if configuration.provider != .external {
                HStack {
                    Label(engine.tunnelToolPath != nil || !configuration.executable.isEmpty ? "Cloudflare 연결 도구 준비됨" : "Cloudflare 연결 도구 필요",systemImage:engine.tunnelToolPath != nil || !configuration.executable.isEmpty ? "checkmark.circle" : "arrow.down.circle")
                        .font(.caption)
                    Spacer()
                    Button(installing ? "설치 중…" : "연결 도구 설치") {
                        busy=true; installing=true; error=nil
                        Task {
                            do { try await engine.installTunnelTool(); configuration.executable="" }
                            catch { self.error=error.localizedDescription }
                            busy=false; installing=false
                        }
                    }.disabled(busy || status.active).help("Cloudflare 공식 파일과 고정 SHA-256을 확인한 뒤 이 앱 전용 폴더에 설치합니다. 관리자 권한은 사용하지 않습니다.")
                }
            }
            DisclosureGroup("연결 세부 설정") {
                HStack {
                    Text("서비스 포트"); TextField("8766",text:$port).textFieldStyle(.roundedBorder).frame(width:90)
                        .accessibilityLabel("터널 서비스 포트").disabled(busy || status.active)
                    if !validPort { Text("1~65535").font(.caption).foregroundStyle(.red) }
                }
                if configuration.provider != .external {
                    HStack {
                        Button("cloudflared 파일 선택") { chooseExecutable() }.disabled(busy || status.active)
                        if !configuration.executable.isEmpty { Button("기본 도구 사용") { configuration.executable="" }.disabled(busy || status.active) }
                    }
                    if !configuration.executable.isEmpty { Text(configuration.executable).font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                }
                Text("서비스 포트는 이 Mac 안에서만 열립니다. 연결을 켠 설정은 앱 재실행 후 복원하며, 접속 키는 새로 발급합니다. 종료하면 외부 연결과 기존 접속도 해제합니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            HStack {
                if !status.active {
                    Button(status.phase == "failed" ? "다시 연결" : "연결 시작") { connect() }
                        .disabled(busy || !validPort || !engine.webStatus.ready)
                        .help(engine.webStatus.ready ? "인증 접속 키와 외부 주소를 만듭니다." : "먼저 같은 네트워크에서 웹 접속을 켜주세요.")
                }
                if status.phase != "off" {
                    Button("연결 종료") { do { try engine.stopTunnel(); error=nil } catch { self.error=error.localizedDescription } }
                        .disabled(busy).help("터널과 모든 외부 접속을 해제합니다. 기존 원본 CLI는 유지합니다.")
                }
                if status.active && !status.ready || busy { ProgressView().controlSize(.small).accessibilityLabel("터널 연결 작업 중") }
            }
            Text(status.detail).font(.callout).foregroundStyle(status.phase == "failed" ? .red : .secondary)
                .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            if !engine.webStatus.ready { Text("같은 네트워크에서 웹 접속을 먼저 켜주세요.").font(.caption).foregroundStyle(.secondary) }
            if let link=engine.tunnelShareURL, let address=status.publicURL {
                HStack(alignment:.top,spacing:16) {
                    if let qr=qrCodes.image(for:link.absoluteString) {
                        Image(nsImage:qr).interpolation(.none).resizable().frame(width:116,height:116).padding(8).background(.white)
                            .clipShape(RoundedRectangle(cornerRadius:8)).accessibilityLabel("인증 키가 포함된 외부 접속 QR 코드")
                    }
                    VStack(alignment:.leading,spacing:8) {
                        Text(address).font(.system(.callout,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        ShareLink(item:link) { Label("접속 링크 공유",systemImage:"square.and.arrow.up") }
                        HStack {
                            Button("접속 링크 복사") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.absoluteString,forType:.string) }
                            Link("웹에서 열기",destination:link)
                        }
                        Text("QR과 접속 링크에 키가 포함됩니다. 브라우저 접속은 최대 8시간 유지됩니다.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
                DisclosureGroup("접속 키 직접 입력") {
                    if let key=engine.tunnelAccessKey {
                        Text(key).font(.system(.caption,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        Button("접속 키 복사") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key,forType:.string) }
                    }
                }.font(.caption)
            }
            if let error { Label(error,systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
        }.frame(maxWidth:.infinity,alignment:.leading)
            .windowUpdates(updates,sources:[engine.objectWillChange])
            .onAppear { configuration=engine.tunnelConfiguration; port=String(configuration.port) }
    }
    private func connect() {
        guard let number=UInt16(port), number > 0 else { return }
        configuration.port=number; busy=true; error=nil
        let secret=token; token=""
        Task {
            do { try await engine.startTunnel(configuration,token:secret) }
            catch is CancellationError {} catch { self.error=error.localizedDescription }
            busy=false
        }
    }
    private func chooseExecutable() {
        let panel=NSOpenPanel(); panel.canChooseFiles=true; panel.canChooseDirectories=false; panel.allowsMultipleSelection=false
        panel.message="cloudflared 실행 파일을 선택하세요."
        if panel.runModal() == .OK, let url=panel.url {
            if FileManager.default.isExecutableFile(atPath:url.path) { configuration.executable=url.path; error=nil }
            else { error="실행 가능한 cloudflared 파일을 선택해주세요." }
        }
    }
}
