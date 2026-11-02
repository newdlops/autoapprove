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
            copy: { code in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) },
            open: { value in
                guard AgentAccountOutput.validURL(value, agent: "codex"), let url = URL(string: value), NSWorkspace.shared.open(url) else {
                    error = "인증 페이지를 열지 못했습니다. 표시된 공식 주소를 브라우저에서 열어주세요."; return
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
    let copy: (String) -> Void
    let open: (String) -> Void
    @State private var copied = false
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
            Text("공식 인증 페이지에서 사용할 계정으로 로그인합니다. 기존 창은 유지됩니다.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(job == nil ? "Codex 로그인 시작" : "다시 로그인") { copied = false; begin() }
                    .disabled(active || loading || disabled)
                    .help(disabled ? "진행 중인 서버 전환이 끝난 뒤 로그인해주세요." : "선택한 Codex 홈에서 공식 기기 인증을 시작합니다.")
                if active { Button("로그인 취소", action: cancel) }
                if loading { ProgressView().controlSize(.small).accessibilityLabel("Codex 홈 확인 중") }
            }
            if let job {
                HStack(spacing: 6) {
                    if ["starting", "verifying"].contains(job.phase) { ProgressView().controlSize(.small) }
                    Text(title(job)).foregroundStyle(job.phase == "succeeded" ? Color.green : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                if job.phase == "waiting", let code = job.code {
                    HStack(spacing: 12) {
                        Text(code).font(.title3.monospaced().weight(.semibold)).foregroundStyle(.primary).textSelection(.enabled)
                            .accessibilityLabel("인증 코드 \(code)")
                        Button(copied ? "복사됨" : "코드 복사") { copy(code); copied = true }
                    }
                }
                if job.phase == "waiting", let url = job.url, AgentAccountOutput.validURL(url, agent: "codex") {
                    Button("공식 인증 페이지 열기") { open(url) }
                    Text(url).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("페이지에 코드를 입력한 뒤 이 창에서 로그인 완료를 기다려주세요.").font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text(transitionEnabled ? "로그인을 마치면 아래 자동 전환이 계정 변경을 확인합니다." : "현재 자동 전환이 꺼져 있습니다. 기존 작업을 순차 중단하고 새 계정에 연결하려면 아래에서 켜주세요.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func title(_ job: NativeCodexLoginState) -> String {
        switch job.phase {
        case "starting": return "공식 인증 코드를 받는 중…"
        case "waiting": return "브라우저에서 로그인해주세요"
        case "verifying": return "로그인 완료 확인 중…"
        default: return job.message ?? "로그인 상태를 확인해주세요."
        }
    }
}
