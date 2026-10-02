import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import AutoApproveCore

struct RemoteAccessSettings: View {
    @ObservedObject var engine: ApprovalEngine
    @State private var error: String?
    @State private var selectedURL = ""
    var body: some View {
        let status = engine.webStatus
        let phoneURLs = status.directURLs
        let url = phoneURLs.contains(selectedURL) ? selectedURL : phoneURLs.first
        VStack(alignment: .leading, spacing: 10) {
            Label("같은 네트워크에서 웹 접속", systemImage: "iphone.and.arrow.forward").font(.headline)
            Text(status.detail).font(.callout.weight(.medium)).textSelection(.enabled)
            Text("앱을 처음 실행하면 웹페이지를 열고 같은 네트워크의 AutoApprove를 자동으로 찾습니다. 어느 Mac의 주소로 접속해도 발견한 모든 Mac의 세션·터미널을 보고 제어할 수 있습니다. 휴대폰 앱 설치나 연결 코드는 필요 없습니다.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("같은 네트워크에서 웹 접속", isOn: Binding(get: { status.enabled }, set: { enabled in
                do { try engine.setWebEnabled(enabled); error = nil } catch { self.error = error.localizedDescription }
            })).toggleStyle(.switch)
                .help("개인 핫스팟의 기기에서 로그인 없이 터미널과 자동 승인을 제어할 수 있습니다. 끄면 웹 접속과 Mac 자동 발견을 중단합니다.")
            if status.enabled && !status.ready {
                Button("웹 연결 다시 시도") {
                    do { try engine.setWebEnabled(false); try engine.setWebEnabled(true); error = nil } catch { self.error = error.localizedDescription }
                }.help("웹 연결을 다시 열고 같은 네트워크의 Mac을 찾습니다.")
            }
            if let url, let address = URL(string: url) {
                HStack(alignment: .top, spacing: 16) {
                    if let qr = qrCode(url) {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 116, height: 116)
                            .padding(8).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("휴대폰 카메라로 스캔할 웹 접속 QR 코드")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("이 주소에서 전체 Mac 목록을 여세요.").font(.callout.weight(.medium))
                        Text("링크를 공유해 휴대폰에서 여세요. QR로 열 수도 있습니다.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if phoneURLs.count > 1 {
                            Picker("접속 주소", selection: Binding(get: { url }, set: { selectedURL = $0 })) {
                                ForEach(phoneURLs, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().accessibilityLabel("휴대폰과 연결된 네트워크의 접속 주소")
                                .help("휴대폰과 같은 네트워크의 주소를 선택하면 QR 코드와 복사할 주소가 함께 바뀝니다.")
                        }
                        Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        ShareLink(item: address) {
                            Label("휴대폰으로 공유", systemImage: "square.and.arrow.up")
                        }.help("선택한 접속 링크를 macOS 공유 메뉴로 전달합니다.")
                        HStack {
                            Button("주소 복사") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }
                                .help("휴대폰에서 열 웹 주소를 복사합니다.")
                            Link("웹 관리 열기", destination: address).help("기본 브라우저에서 같은 네트워크의 웹 관리 화면을 엽니다.")
                        }
                        Text("한 번 열고 즐겨찾기에 저장하세요. 핫스팟에서 Mac 주소가 바뀌면 새 링크를 공유하세요.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("다른 Mac \(status.peerCount)대 발견 · 이 설정은 재실행 후 유지됩니다.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if phoneURLs.count > 1 {
                    Text("열리지 않으면 휴대폰과 연결된 네트워크의 주소를 선택해 다시 공유하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let namedURLs = status.urls.filter { !phoneURLs.contains($0) }
                if !namedURLs.isEmpty {
                    DisclosureGroup("이름으로 접속 · 지원되는 네트워크") {
                        Text("핫스팟을 제공하는 휴대폰에서는 .local 이름이 열리지 않을 수 있습니다. 이때는 위 접속 링크를 공유하세요.")
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(namedURLs, id: \.self) { url in Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }.font(.caption)
                }
            } else if status.ready {
                Text("휴대폰에 전달할 직접 접속 주소가 없습니다. Mac을 휴대폰의 핫스팟에 연결하면 QR 코드가 표시됩니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("자동 발견이 되지 않으면 웹 화면의 ‘Mac 추가’에서 각 Mac의 주소를 입력하세요. 처음 켤 때 macOS 로컬 네트워크 접근을 허용해주세요.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("VPN을 사용해도 Wi-Fi·유선 LAN 주소로 연결합니다. Zscaler에서 로컬 통신을 차단하면 관리자에게 핫스팟 내 접속 허용을 요청해야 합니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
