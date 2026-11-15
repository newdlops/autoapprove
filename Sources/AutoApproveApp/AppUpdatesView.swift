import SwiftUI
import AutoApproveCore

struct AppUpdatesView: View {
    @ObservedObject var model: AppUpdates
    @State private var error: String?
    private var installing: Bool { model.status.update.map { ["checking", "downloading", "waiting", "applying"].contains($0.phase) } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("AutoApprove 업데이트", systemImage: "arrow.down.circle").font(.title2.weight(.semibold))
            if let current = model.status.host {
                Text("현재 버전 \(current.version) · 빌드 \(current.build)").font(.callout).foregroundStyle(.secondary)
            }
            Toggle("새 버전 자동 다운로드 및 적용", isOn: Binding(get: { model.automatic }, set: {
                do { try model.setAutomatic($0); error = nil } catch { self.error = error.localizedDescription }
            })).toggleStyle(.switch)
                .help("앱 시작 시와 매시간 GitHub의 정식 릴리스를 확인하고, 입력 전송이 끝나면 업데이트합니다.")
            Text("GitHub의 정식 릴리스를 앱 시작 시와 매시간 확인합니다. 설정과 세션 데이터는 유지하며, 업데이트를 적용할 때 AutoApprove만 다시 시작합니다.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(model.status.detail).font(.callout)
                .foregroundStyle(model.status.phase == "failed" ? .red : .primary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let update = model.status.update {
                Text(update.detail).font(.callout).foregroundStyle(update.phase == "failed" ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let progress = update.progress {
                    ProgressView(value: Double(progress), total: 100).accessibilityLabel("업데이트 다운로드 \(progress)%")
                } else if ["checking", "applying"].contains(update.phase) {
                    ProgressView().controlSize(.small).accessibilityLabel("업데이트 준비 중")
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(model.status.phase == "checking" ? "확인 중…" : "업데이트 확인") { Task { await model.check() } }
                    .disabled(model.status.phase == "checking" || installing)
                if model.status.canSync {
                    Button("지금 업데이트") { model.apply() }.disabled(installing)
                }
                Spacer()
                Link("릴리스 보기", destination: AppInformation.releases)
            }
            Text("서명과 체크섬을 확인한 파일만 적용합니다. 입력 전송·로그인·화면 공유 중에는 안전하게 적용할 수 있을 때까지 기다립니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: 500, alignment: .leading)
            .task { await model.check() }
    }
}
