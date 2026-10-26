import SwiftUI
import AutoApproveCore

@MainActor struct CloudflareApprovalSteps:View {
    let state:CloudflareSetupStatus
    let tunnelActive:Bool
    let approvalURL:URL?
    let address:String?
    @Binding var domainID:String
    @Binding var subdomain:String
    let subdomainError:String?
    let busy:Bool
    let approve:()->Void
    let reload:()->Void
    let connect:()->Void
    var body:some View {
        let locked=busy || state.busy || tunnelActive
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Label("1. Cloudflare 승인",systemImage:state.authorized ? "checkmark.circle" : "person.crop.circle")
                    .font(.callout.weight(.medium))
                Spacer()
                Button(state.authorized ? "다시 승인" : "Cloudflare에서 승인") {approve()}
                    .disabled(locked).accessibilityIdentifier("cloudflare-approve")
            }
            Text("브라우저에서 한 번 로그인하고 이 Mac에 Cloudflare 계정의 터널 관리와 도메인 연결을 허용하세요.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if state.phase == "authorizing",let url=approvalURL {
                Link("승인 화면 열기",destination:url).font(.callout)
            }
            Text("2. 등록된 도메인 선택").font(.callout.weight(.medium)).padding(.top,4)
            Picker("등록된 도메인",selection:$domainID) {
                Text("도메인을 선택하세요").tag("")
                ForEach(state.domains) {domain in Text(domain.name).tag(domain.id)}
            }.disabled(locked || !state.authorized || state.domains.isEmpty)
                .accessibilityIdentifier("cloudflare-domain")
            VStack(alignment:.leading,spacing:4) {
                Text("서브도메인").font(.callout.weight(.medium))
                TextField("aa",text:$subdomain).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("접속 주소의 서브도메인").accessibilityIdentifier("cloudflare-subdomain")
                    .onSubmit {connect()}.disabled(locked)
                if let subdomainError {
                    Text(subdomainError).font(.caption).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)
                } else {
                    Text(tunnelActive ? "주소를 바꾸려면 연결을 종료한 뒤 다시 연결하세요." : "a, aa, term처럼 짧게 지정하세요. 선택한 도메인 앞에 붙습니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
            if state.authorized && state.domains.isEmpty && !state.busy && state.phase != "failed" {
                Text("조회할 수 있는 등록 도메인이 없습니다. Cloudflare에 도메인을 연결한 뒤 다시 불러오세요.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                HStack {
                    Link("Cloudflare 도메인 열기",destination:URL(string:"https://dash.cloudflare.com/")!)
                    Button("다시 불러오기") {reload()}
                }.font(.callout)
            }
            if let address {
                Text(address).font(.system(.callout,design:.monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal:false,vertical:true).accessibilityLabel("접속 주소 \(address)")
            }
            Text("3. 연결").font(.callout.weight(.medium)).padding(.top,4)
            Text("연결을 누르면 이 Mac의 터널·DNS·웹 접속을 자동으로 설정하고 접속 링크와 QR을 준비합니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if state.phase != "idle" {
                Text(state.detail).font(.callout).foregroundStyle(state.phase == "failed" ? .red : .secondary)
                    .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("cloudflare-status")
            }
        }
    }
}
