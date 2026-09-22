import SwiftUI
import AppKit

struct HelpWindow: View {
    private enum Topic: String, CaseIterable {
        case start = "시작하기", automatic = "자동 응답", troubleshooting = "문제 해결"
    }
    var connectionsAvailable = true
    @Environment(\.openWindow) private var openWindow
    @State private var topic = Topic.start
    @State private var copied = false
    @State private var copyError = false
    @State private var copyReset: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Image(nsImage: AppInformation.icon)
                        .resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AutoApprove").font(.title2.weight(.semibold))
                        Text("터미널 자동 승인 관리").foregroundStyle(.secondary)
                        Text(AppInformation.versionLabel).font(.callout.monospacedDigit())
                            .textSelection(.enabled)
                    }
                }
                HStack(spacing: 12) {
                    Button {
                        copyVersion()
                    } label: {
                        Label(copied ? "복사 완료" : "버전 정보 복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }.help("앱 버전·빌드 번호와 macOS 버전을 복사합니다. 세션이나 요청 내용은 포함하지 않습니다.")
                    Link(destination: AppInformation.releases) {
                        Label("최신 릴리스", systemImage: "arrow.up.right.square")
                    }.help("브라우저에서 GitHub 릴리스를 열어 최신 버전과 변경 내용을 확인합니다.")
                }
                if copyError {
                    Text("버전 정보를 복사하지 못했습니다. 위의 버전 번호를 선택해 복사해주세요.")
                        .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Picker("도움말 주제", selection: $topic) {
                    ForEach(Topic.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
                    .help("시작 방법, 자동 응답 규칙, 문제 해결 안내를 선택합니다.")
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch topic {
                    case .start: gettingStarted
                    case .automatic: automaticReplies
                    case .troubleshooting: troubleshooting
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .textSelection(.enabled)
            }.id(topic)
            Divider()
            HStack(spacing: 16) {
                Link("사용법 문서 ↗", destination: AppInformation.documentation)
                    .help("브라우저에서 자세한 설치·사용 설명서를 엽니다.")
                Link("문제 보고 ↗", destination: AppInformation.issues)
                    .help("브라우저에서 GitHub 이슈 페이지를 엽니다. 작성한 내용은 직접 제출해야 전송됩니다.")
                Spacer(minLength: 0)
                Text("외부 링크는 브라우저에서 열립니다.").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
        .frame(minWidth: 520, minHeight: 540)
        .onDisappear { copyReset?.cancel() }
    }

    private var gettingStarted: some View {
        Group {
            section("1. 터미널에서 작업 시작") {
                Text("Terminal 또는 VS Code에서 Claude Code나 Codex를 실행하세요. 실행 중인 도구의 세션이 관리 창에 표시됩니다.")
            }
            section("2. 사용할 연결 설정") {
                Text("Terminal은 화면 연결을, Claude Code는 훅을, VS Code는 AutoApprove Bridge 확장을 연결합니다. 필요한 권한과 현재 연결 상태는 연결 설정에서 확인할 수 있습니다.")
                Button("연결 설정 열기") { show("settings") }
                    .disabled(!connectionsAvailable)
                    .help(connectionsAvailable ? AppHelp.connections : "앱을 시작하지 못해 연결 설정을 열 수 없습니다. 앱을 다시 실행해주세요.")
            }
            section("3. 세션의 자동 승인 켜기") {
                Text("관리 창에서 대상 세션을 선택하고 자동 승인을 켜세요. 설정은 세션별로 저장됩니다. 행을 더블클릭하면 원래 터미널로 이동합니다.")
                Button("관리 창 열기") { show("main") }.help("세션 목록과 현재 승인 상태를 확인합니다.")
            }
            section("이름·메모·색상으로 구분하기") {
                Text("세션 상세의 ‘표시 편집’이나 행의 우클릭 메뉴에서 이름, 메모와 색상을 지정하세요. 이름과 메모로 검색할 수 있으며 앱을 다시 열어도 유지됩니다. 설정은 개별 실행 세션에 적용됩니다.")
            }
            section("새 알림 배지 읽기") {
                Text("새 질문과 작업 완료가 감지되면 해당 행에 알림 배지가 붙습니다. 관리 창에서 세션을 열람하거나 ‘터미널 열기’에 성공하면 배지가 사라집니다. 최근 알림 내용과 답변이 필요한 질문은 상세에 남습니다. Terminal 자체의 탭·Dock 배지를 복제하는 기능은 아닙니다.")
            }
            section("자주 쓰는 단축키") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    shortcut("관리 창 열기", keys: "⌘O")
                    shortcut("연결 설정", keys: "⌘,")
                    shortcut("승인 내역", keys: "⇧⌘H")
                    shortcut("도움말", keys: "⌘/")
                    shortcut("관리 창 새로고침", keys: "⌘R")
                    shortcut("앱 종료", keys: "⌘Q")
                }
            }
        }
    }

    private var automaticReplies: some View {
        Group {
            section("새 확인 질문에는 5초 후 예 · 허용") {
                Text("자동 승인이 켜진 세션의 새 Claude 요청과 Codex 확인 질문마다 5초를 기다립니다. Yes, Allow, 예, 허용 등 이번 요청을 허용하는 원래 선택지로 답합니다. 항상 허용 선택지가 함께 있어도 이번 요청만 허용합니다.")
            }
            section("Claude 요청을 앱에서 허용하기") {
                Text("현재 요청에서 ‘허용’이나 ‘예’를 누르면 해당 질문에 답합니다. ‘허용하고 자동 승인 켜기’는 이번 요청에 답하고 다음 지원 요청도 이어서 처리합니다. 메인에서 시작한 백그라운드 질문도 같은 화면에서 응답합니다.")
                Text("‘터미널에서 답하기’를 누르거나 앱 응답 대기가 10분을 넘으면 원래 터미널에서 답할 수 있습니다. 앱이 짧게 재시작되어도 같은 요청을 이어받습니다. 이미 터미널로 넘긴 예전 질문은 그곳에서 처리해주세요.")
            }
            section("직접 답변을 시작하면 자동 응답 중지") {
                Text("Codex 질문에서 선택지를 고르거나 답변 입력란에 포커스를 두거나 입력하면 해당 질문의 카운트다운을 멈춥니다. ‘자동 응답 취소’로 질문 하나만 멈출 수도 있습니다. 직접 답변·개별 취소 상태는 새로고침과 앱 재실행 후에도 유지됩니다.")
            }
            section("직접 확인해야 하는 질문") {
                Text("과거 기록에서 복원한 질문, 문구가 같은 중복 질문, 뒤에 사용자 메시지가 있는 질문은 자동으로 답하지 않습니다. 작업·환경 선택처럼 명확한 예·아니오가 아닌 질문도 직접 선택해주세요.")
            }
            section("일시정지와 전달 대기") {
                Text("전체 일시정지는 새 자동 승인만 멈춥니다. 재개하면 처리 가능한 Codex 질문은 새로 5초를 기다립니다. 이미 시작된 터미널 작업은 계속됩니다.")
                Text("‘전달 대기’는 답변을 저장하고 도구가 받기를 기다리는 상태입니다. Claude는 같은 요청의 응답만 재전달하고 수신을 확인하면 내역을 갱신합니다. Codex에서 접수 결과를 확인하지 못한 답변은 자동 재전송하지 않습니다.")
            }
            section("터미널 권한 확인과 Claude 훅") {
                Text("터미널의 지원 권한 확인 화면은 연결된 탭에서 처리합니다. Claude의 ‘예/아니오’, ‘네/아니요’, ‘허용/항상 허용/거부’ 질문은 앱으로 받아 응답합니다.")
                Text("자동 승인이 꺼져 있거나 전체 일시정지 중이면 직접 허용할 수 있습니다. 이미 터미널로 넘긴 질문은 자동 승인을 나중에 켜도 다시 보내지 않습니다.")
            }
        }
    }

    private var troubleshooting: some View {
        Group {
            section("세션이 보이지 않아요") {
                Text("이 Mac의 Terminal 또는 VS Code에서 Claude Code·Codex가 실행 중인지 확인하세요. 일반 셸과 종료된 세션은 표시하지 않습니다. 검색어·필터를 지운 뒤 관리 창을 새로고침하세요.")
            }
            section("자동 승인이 멈췄어요") {
                Text("전체 일시정지와 해당 세션의 자동 승인 스위치, 연결 상태를 확인하세요. ‘연결 필요’는 연결 설정에서 복구할 수 있습니다. ‘확인 필요’나 전송 오류는 승인 내역의 사유를 읽고 원래 터미널에서 확인하세요.")
                Button("연결 설정 열기") { show("settings") }.disabled(!connectionsAvailable).help(AppHelp.connections)
            }
            section("VS Code 출력이 감지되지 않아요") {
                Text("확장을 연결하기 전에 나온 출력은 복구할 수 없습니다. 확장이 연결된 뒤 CLI를 다시 실행하고 대화를 이어가세요. SSH·Dev Containers·WSL은 지원하지 않습니다.")
            }
            section("Claude 백그라운드로 표시돼요") {
                Text("Claude가 백그라운드 실행기에 만든 가상 터미널입니다. TTY가 있어도 독립된 Terminal·VS Code 탭이 아니므로 원래 Claude 세션에서 확인하세요. 훅으로 받은 요청의 자동 승인은 이 세션의 스위치를 따릅니다.")
            }
            section("알림을 받지 못했어요") {
                Text("작업 완료와 오래 기다리는 질문만 알립니다. 질문 대기는 기본 10초이며 연결 설정의 ‘질문 대기 시간’에서 1~3600초로 바꿀 수 있습니다. 그 전에 처리된 질문은 알리지 않습니다. 연결 설정의 알림 권한과 macOS 알림·집중 모드를 확인하세요. 앱 창을 닫아도 계속 동작하지만, 앱을 종료하면 자동 승인과 알림도 중지됩니다.")
            }
            section("업데이트하거나 문제를 보고하려면") {
                Text("상단의 ‘최신 릴리스’에서 배포 버전을 확인하세요. 실행 중인 앱을 종료하고 새 앱으로 교체한 뒤 다시 열면 기존 설정과 승인 내역을 유지합니다.")
                Text("문제를 보고할 때는 ‘버전 정보 복사’와 함께 발생 상황을 적어주세요. 터미널 명령과 대화 내용은 필요한 부분만 직접 확인해 첨부하세요.")
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content().font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        GridRow { Text(title); Text(keys).foregroundStyle(.secondary) }
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func copyVersion() {
        copyReset?.cancel()
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(AppInformation.versionDetails, forType: .string)
        copyError = !copied
        copyReset = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            copied = false
        }
    }
}
