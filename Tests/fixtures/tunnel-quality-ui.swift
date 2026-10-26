import SwiftUI
import AppKit
import AutoApproveCore

@MainActor private final class QualityModel:ObservableObject {
    @Published var scenario = "connected"
    @Published var dark = false
    @Published var measuring = false
    @Published var measurements = 0
    @Published var checked = Date()
    let output:URL
    init(_ output:URL) {self.output = output}
    var quality:RemoteTunnelQuality {
        var q = RemoteTunnelQuality()
        if scenario == "waiting" {return q}
        if scenario == "first-failure" {q.succeeded = false;q.checkedAt = checked;q.failedProbes = 1;return q}
        q.samples = 64;q.medianMS = measurements > 0 ? 281:319;q.p95MS = 408;q.lastMS = 281;q.checkedAt = checked;q.succeeded = scenario != "failure"
        q.edge = "LAX";q.connectorProtocol = "QUIC";q.connectorLocations = ["ICN","NRT"];q.connectorMS = 35;q.connections = 4;q.lostPackets = 2;q.reconnects = 1
        if scenario == "failure" {q.failedProbes = 2}
        if scenario == "long" {q.medianMS = 60000;q.p95MS = 60000;q.connectorLocations = ["AMS","CDG","FRA","ICN","LAX","NRT","SIN","SJC"];q.reconnects = .max}
        if scenario == "legacy" {q.relayCompatibility = true;q.connectorProtocol = "WSS 443";q.connectorLocations = [];q.connections = nil;q.lostPackets = nil}
        return q
    }
    func measure() async {
        measuring = true;persist();try? await Task.sleep(for:.milliseconds(800))
        measurements += 1;checked = Date();measuring = false;persist()
    }
    func persist() {
        let object:JSONObject = ["scenario":scenario,"dark":dark,"measuring":measuring,"measurements":measurements,"synthetic":true]
        try? JSONSerialization.data(withJSONObject:object).write(to:output.appendingPathComponent("quality-ui-status.json"),options:.atomic)
    }
}

@MainActor private struct QualityRoot:View {
    @ObservedObject var model:QualityModel
    let appearance:(Bool)->Void
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("연결 품질 확인 · 합성 계측").font(.headline)
            Picker("계측 상태",selection:$model.scenario) {
                Text("연결됨").tag("connected");Text("첫 측정 대기").tag("waiting")
                Text("첫 확인 실패").tag("first-failure");Text("최근 확인 실패").tag("failure")
                Text("긴 지점과 숫자").tag("long");Text("중계 호환 모드").tag("legacy")
            }.accessibilityIdentifier("quality-scenario")
            Toggle("다크 모드",isOn:$model.dark).accessibilityIdentifier("quality-dark")
            Divider()
            ScrollView {
                TunnelConnectionQuality(quality:model.quality,enabled:model.scenario != "waiting",measure:{await model.measure()})
                    .padding(.vertical,4)
            }
            Text("실제 연결·계정·PIN·사용자 터미널을 변경하지 않는 UI 검증입니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(24).frame(minWidth:420,minHeight:400)
            .environment(\.colorScheme,model.dark ? .dark:.light)
            .onChange(of:model.scenario) {_,_ in model.persist()}
            .onChange(of:model.dark) {_,value in appearance(value);model.persist()}
    }
}

@main struct TunnelQualityUI {
    @MainActor static func main() {
        let app = NSApplication.shared;app.setActivationPolicy(.regular)
        let output = Bundle.main.bundleURL.deletingLastPathComponent(),model = QualityModel(output)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:560),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.title = "AutoApprove · 연결 품질 QA";window.appearance = NSAppearance(named:.aqua)
        window.contentView = NSHostingView(rootView:QualityRoot(model:model,appearance:{[weak window] dark in window?.appearance = NSAppearance(named:dark ? .darkAqua:.aqua)}))
        window.center();window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true);model.persist()
        Task { @MainActor in while true {if FileManager.default.fileExists(atPath:output.appendingPathComponent("quality-stop").path) {app.terminate(nil);return};try? await Task.sleep(for:.milliseconds(100))} }
        app.run()
    }
}
