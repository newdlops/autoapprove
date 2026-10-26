import SwiftUI
import AutoApproveCore

@MainActor struct TunnelConnectionQuality:View {
    let quality:RemoteTunnelQuality
    let enabled:Bool
    let measure:@MainActor () async -> Void
    @State private var measuring = false
    private func milliseconds(_ value:Double?) -> String {value.map {String(format:"%.0f ms",$0)} ?? "첫 측정 대기"}
    private func metric(_ label:String,_ value:String) -> some View {
        LabeledContent(label,value:value).accessibilityElement(children:.ignore)
            .accessibilityLabel(Text(label)).accessibilityValue(Text(value))
    }
    var body:some View {
        DisclosureGroup("연결 품질") {
            VStack(alignment:.leading,spacing:8) {
                metric("공개 주소 왕복",milliseconds(quality.medianMS))
                if quality.samples > 0 {metric("느린 응답 · 95%",milliseconds(quality.p95MS))}
                if let edge = quality.edge {metric("Cloudflare 처리 지점",edge)}
                if let transport = quality.connectorProtocol {metric("Mac 연결 방식",transport)}
                if quality.connectorMS != nil {metric("Mac ↔ Cloudflare",milliseconds(quality.connectorMS))}
                if !quality.connectorLocations.isEmpty {metric("Mac 연결 지점",quality.connectorLocations.joined(separator:" · "))}
                if let connections = quality.connections {metric("유지 중인 연결",String(connections))}
                if let lost = quality.lostPackets {metric("누적 손실 패킷",String(lost))}
                metric("재연결",String(quality.reconnects)+"회")
                if quality.relayCompatibility == true {Text("중계 업데이트 대기 · 다시 연결하면 업데이트를 재시도합니다. 현재 연결은 호환 모드로 유지합니다.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                if quality.succeeded == false {Text(quality.samples > 0 ? "최근 공개 주소 확인에 실패했습니다. 위 지연은 마지막 성공한 측정값입니다.":"공개 주소 응답을 확인하지 못했습니다. 연결 상태를 확인한 뒤 다시 측정하세요.").foregroundStyle(.primary).fixedSize(horizontal:false,vertical:true)}
                HStack(spacing:8) {
                    Button(measuring ? "측정 중…":"다시 측정") {
                        guard !measuring else {return};measuring = true
                        Task {await measure();measuring = false}
                    }.disabled(measuring || !enabled).accessibilityIdentifier("tunnel-measure")
                    if let checked = quality.checkedAt {Text(checked,style:.time).foregroundStyle(.secondary)}
                }
                Text("이 Mac에서 측정합니다. 접속 기기의 입력 지연은 웹 터미널 상단에서 확인하세요.")
                    .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.font(.caption).padding(.top,4).accessibilityElement(children:.contain)
        }.font(.caption)
    }
}
