import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import AutoApproveCore

struct RemoteAccessSettings: View {
    @ObservedObject var engine: ApprovalEngine
    @State private var error: String?
    var body: some View {
        let status = engine.webStatus
        VStack(alignment: .leading, spacing: 10) {
            Label("같은 네트워크에서 웹 접속", systemImage: "iphone.and.arrow.forward").font(.headline)
            Text(status.detail).font(.callout.weight(.medium)).textSelection(.enabled)
            Text("같은 개인 핫스팟의 휴대폰 브라우저에서 여러 Mac의 세션·터미널을 보고 자동 승인과 일시정지를 조절합니다. 각 Mac에서 켜면 서로 자동으로 연결하며 연결 코드 없이 접속합니다.")
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
            if let url = status.urls.first, let address = URL(string: url) {
                HStack(alignment: .top, spacing: 16) {
                    if let qr = qrCode(url) {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 116, height: 116)
                            .padding(8).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("휴대폰 카메라로 스캔할 웹 접속 QR 코드")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("휴대폰에서 주소를 열거나 QR 코드를 스캔하세요.").font(.callout)
                        Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("주소 복사") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }
                                .help("휴대폰에서 열 웹 주소를 복사합니다.")
                            Link("웹 관리 열기", destination: address).help("기본 브라우저에서 같은 네트워크의 웹 관리 화면을 엽니다.")
                        }
                        Text("주소를 즐겨찾기나 홈 화면에 저장하면 IP를 찾아 입력할 필요가 없습니다.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("다른 Mac \(status.peerCount)대 발견 · 이 설정은 재실행 후 유지됩니다.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if status.urls.count > 1 {
                    DisclosureGroup("다른 네트워크 주소") {
                        ForEach(Array(status.urls.dropFirst()), id: \.self) { url in Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }.font(.caption)
                }
            } else if status.ready {
                Text("휴대폰과 같은 핫스팟에 연결하면 접속 주소가 표시됩니다.").font(.caption).foregroundStyle(.secondary)
            }
            Text("자동 발견이 되지 않으면 웹 화면의 ‘Mac 추가’에서 각 Mac의 주소를 입력하세요. 처음 켤 때 macOS 로컬 네트워크 접근을 허용해주세요.")
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
