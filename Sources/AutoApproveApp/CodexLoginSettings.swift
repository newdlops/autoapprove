import SwiftUI
import AppKit
import AutoApproveCore

@MainActor struct CodexLoginSettings: View {
    let accounts: AgentAccounts
    let targets: () async throws -> [CodexAccountTransitionTarget]
    let transitionEnabled: Bool
    let transitionBusy: Bool
    let completed: () async -> Void
    @State private var homes: [CodexAccountTransitionTarget] = []
    @State private var selected = NSHomeDirectory() + "/.codex"
    @State private var loading = true
    @State private var job: NativeCodexLoginState?
    @State private var error: String?
    var body: some View {
        CodexLoginContent(homes: homes.map(\.home), selected: $selected, loading: loading,
            job: job, disabled: transitionBusy, error: error, transitionEnabled: transitionEnabled,
            begin: {
                do {
                    let target = homes.first { $0.home == selected } ?? .init(home: selected, executable: "codex")
                    try accounts.beginNativeCodexLogin(target); job = accounts.nativeCodexLogin; error = nil
                } catch { self.error = error.localizedDescription }
            }, cancel: { accounts.cancelNativeCodexLogin(); job = accounts.nativeCodexLogin },
            open: { value in
                guard AgentAccountOutput.validURL(value, agent: "codex-browser"), let url = URL(string: value), NSWorkspace.shared.open(url) else {
                    error = "로그인 페이지를 열지 못했습니다. 브라우저 연결을 확인하고 다시 시도해주세요."; return
                }
            })
        .task {
            job = accounts.nativeCodexLogin
            do {
                var found = try await targets()
                let defaultHome = NSHomeDirectory() + "/.codex"
                if !found.contains(where: { $0.home == defaultHome }) { found.insert(.init(home: defaultHome, executable: "codex"), at: 0) }
                homes = found
                if let job, found.contains(where: { $0.home == job.home }) { selected = job.home }
            } catch { self.error = "실행 중인 Codex 위치를 조회하지 못했습니다. 기본 홈으로 로그인할 수 있습니다." }
            loading = false
            while !Task.isCancelled {
                let next = accounts.nativeCodexLogin
                let succeeded = next?.phase == "succeeded" && job?.phase != "succeeded"
                job = next
                if succeeded { await completed() }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
}

struct CodexLoginContent: View {
    let homes: [String]
    @Binding var selected: String
    let loading: Bool
    let job: NativeCodexLoginState?
    let disabled: Bool
    let error: String?
    let transitionEnabled: Bool
    let begin: () -> Void
    let cancel: () -> Void
    let open: (String) -> Void
    private var active: Bool { job?.active == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Codex 로그인").font(.callout.weight(.semibold)).foregroundStyle(.primary)
            if homes.count > 1 {
                Picker("로그인할 Codex 홈", selection: $selected) {
                    ForEach(homes, id: \.self) { Text($0).tag($0) }
                }.disabled(active || loading || disabled)
            }
            Text(active ? job?.home ?? selected : selected)
                .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("기본 브라우저에서 계정을 선택하면 이 창에 로그인 완료가 표시됩니다. 기존 창은 유지됩니다.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(job == nil ? "브라우저로 로그인" : "다시 로그인", action: begin)
                    .disabled(active || loading || disabled)
                    .help(disabled ? "진행 중인 서버 전환이 끝난 뒤 로그인해주세요." : "선택한 Codex 홈에서 공식 브라우저 로그인을 시작합니다.")
                if active { Button("로그인 취소", action: cancel) }
                if loading { ProgressView().controlSize(.small).accessibilityLabel("Codex 홈 확인 중") }
            }
            if let job {
                HStack(spacing: 6) {
                    if ["starting", "verifying"].contains(job.phase) { ProgressView().controlSize(.small) }
                    Text(title(job)).foregroundStyle(job.phase == "succeeded" ? Color.green : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                if job.phase == "waiting", let url = job.url, AgentAccountOutput.validURL(url, agent: "codex-browser") {
                    Button("로그인 페이지 다시 열기") { open(url) }
                    Text("auth.openai.com").font(.caption)
                    Text("열린 브라우저에서 로그인한 뒤 이 창에서 완료를 기다려주세요.").font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("로그인 완료 후 열린 Codex 작업을 순차 중단합니다. Goal은 일시정지하고 Codex 백그라운드 작업은 종료한 뒤 새 계정으로 전환합니다. 설정 창을 닫아도 계속 진행합니다.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func title(_ job: NativeCodexLoginState) -> String {
        switch job.phase {
        case "starting": return "브라우저 로그인 준비 중…"
        case "waiting": return "브라우저에서 로그인해주세요"
        case "verifying": return "로그인 완료 확인 중…"
        default: return job.message ?? "로그인 상태를 확인해주세요."
        }
    }
}
