import SwiftUI
import AutoApproveCore

@MainActor struct TunnelPINSettings:View {
    let configured:Bool
    let save:(String) async throws -> Void
    let clear:() throws -> Void
    @State private var pin=""
    @State private var saving=false
    @State private var error:String?
    @State private var saved=false
    @State private var task:Task<Void,Never>?
    private var valid:Bool {RemoteTunnelPIN.valid(pin)}
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            Label(configured ? "접속 PIN 설정됨":"내 접속 PIN",systemImage:"lock").font(.callout.weight(.medium))
            HStack {
                SecureField(configured ? "새 PIN · 숫자 6~12자리":"숫자 6~12자리",text:$pin).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("직접 지정할 접속 PIN").accessibilityIdentifier("tunnel-pin").onSubmit {store()}.disabled(saving)
                Button(saving ? "저장 중…":configured ? "PIN 변경":"PIN 설정") {store()}
                    .disabled(saving || !valid).accessibilityIdentifier("tunnel-pin-save")
                if configured {Button("해제") {do{try clear();pin="";error=nil;saved=false}catch{self.error=error.localizedDescription}}.disabled(saving).accessibilityIdentifier("tunnel-pin-clear")}
            }
            if let error {Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
            else if !pin.isEmpty && !valid {Text("숫자 6~12자리를 입력하세요. 앞의 0도 유지됩니다.").font(.caption).foregroundStyle(.red)}
            else {Text(saved ? "PIN을 저장했습니다. 기존 로그인은 해제됐습니다.":configured ? "LAN의 AI 계정 로그인과 외부 접속에 사용합니다. Cloudflare 연결 없이 PIN만 사용할 수 있습니다.":"LAN의 AI 계정 로그인에도 사용합니다. Cloudflare 연결 없이 설정할 수 있고 PIN은 키체인에 보호해 저장합니다.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
        }.padding(.top,6).onChange(of:pin) {if !pin.isEmpty {saved=false;error=nil}}.onDisappear {task?.cancel()}
    }
    private func store() {
        guard valid,!saving else {return};saving=true;error=nil;let value=pin
        task=Task {do {try await save(value);pin="";saved=true}catch is CancellationError {}catch{self.error=error.localizedDescription};saving=false;task=nil}
    }
}
