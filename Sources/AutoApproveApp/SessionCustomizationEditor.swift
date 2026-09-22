// THESIS: Give a terminal a recognizable name, note and color without changing its identity.
// OWN-WORLD: Existing macOS fields, buttons, system colors and 24pt outer padding.
// STORY: Identify the selected session, edit a private draft, then save or cancel.
// FIRST VIEWPORT: Name, multiline note and named color choices above the action row.
// FORM: A native editing sheet protects one session's draft while discovery continues.
import SwiftUI
import AutoApproveCore

extension SessionColor {
    var swatch: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }
}

struct SessionColorTag: View {
    let color: SessionColor
    var selected = false
    var body: some View {
        Image(systemName: "tag.fill").font(.system(size: 12))
            .foregroundStyle(color.swatch)
            .padding(2)
            .background(selected ? Color(nsColor: .textBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 3))
            .accessibilityLabel("식별 색상: \(color.title)")
            .help("식별 색상: \(color.title). 작업 상태와는 별도로 지정한 색상입니다.")
    }
}

struct SessionCustomizationEditor: View {
    let session: AgentSession
    let isAvailable: Bool
    let save: (SessionCustomization) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var draft: SessionCustomization
    @State private var error: String?

    init(session: AgentSession, isAvailable: Bool, save: @escaping (SessionCustomization) throws -> Void) {
        self.session = session; self.isAvailable = isAvailable; self.save = save
        _draft = State(initialValue: session.customization ?? SessionCustomization())
    }

    private var validationError: String? {
        do { _ = try draft.normalized(); return nil }
        catch { return error.localizedDescription }
    }
    private var changed: Bool {
        (try? draft.normalized()) != (session.customization ?? SessionCustomization())
    }
    private var canSave: Bool { isAvailable && validationError == nil && changed }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("터미널 표시 편집").font(.title2.weight(.semibold))
                Text("\(session.project) · \(session.tty)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .help("\(session.cwd)\n\(session.tty) · PID \(session.pid)")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("표시 이름").font(.headline)
                TextField("예: 결제 API 수정", text: $draft.title)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                    .accessibilityLabel("표시 이름")
                    .help("AutoApprove에서 사용할 이름입니다. 비워두면 실제 터미널 제목을 표시합니다.")
                HStack(alignment: .top) {
                    Text("AutoApprove 안에서만 사용합니다. 비워두면 원래 제목을 표시합니다.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("\(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).count)/\(SessionCustomization.titleLimit)")
                        .monospacedDigit().fixedSize()
                }.font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("메모").font(.headline)
                    Spacer()
                    Text("\(draft.note.trimmingCharacters(in: .whitespacesAndNewlines).count)/\(SessionCustomization.noteLimit.formatted())")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                TextEditor(text: $draft.note).font(.body)
                    .frame(height: 112).padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                    .accessibilityLabel("세션 메모")
                    .help("작업 목적이나 다음 할 일을 여러 줄로 적을 수 있습니다. 이름과 메모로 세션을 검색할 수 있습니다.")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("식별 색상").font(.headline)
                HStack(spacing: 6) {
                    colorChoice(nil)
                    ForEach(SessionColor.allCases, id: \.self) { colorChoice($0) }
                }
            }.disabled(!isAvailable)
            if !isAvailable {
                notice("이 세션이 종료되었습니다. 작성한 내용을 복사한 뒤 닫아주세요.")
            } else if let message = validationError ?? error {
                notice(message)
            }
            Divider()
            HStack(spacing: 10) {
                Button("초기화") { draft = SessionCustomization() }
                    .disabled(draft.isEmpty || !isAvailable)
                    .help("이름·메모·색상을 비웁니다. 저장을 눌러야 적용됩니다.")
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                    .help("변경 사항을 저장하지 않고 닫습니다.")
                Button("저장") {
                    do { try save(draft); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(!canSave)
                    .help(!isAvailable ? "종료된 세션에는 저장할 수 없습니다." : validationError ?? (changed ? "이 세션의 이름·메모·색상을 저장합니다." : "변경한 내용이 없습니다."))
            }
        }.padding(24).frame(width: 520)
            .onAppear { nameFocused = true }
            .onChange(of: draft) { _, _ in error = nil }
    }

    private func colorChoice(_ color: SessionColor?) -> some View {
        let selected = draft.color == color
        let name = color?.title ?? "없음"
        return Button { draft.color = color } label: {
            VStack(spacing: 4) {
                Image(systemName: selected ? "checkmark.circle.fill" : (color == nil ? "circle.slash" : "circle.fill"))
                    .font(.system(size: 16)).foregroundStyle(color?.swatch ?? .secondary)
                Text(name).font(.caption.weight(selected ? .semibold : .regular))
            }.frame(maxWidth: .infinity).padding(.vertical, 3)
        }.buttonStyle(.bordered)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .accessibilityLabel("식별 색상 \(name)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(color == nil ? "식별 색상을 표시하지 않습니다." : "이 세션을 \(name) 태그로 표시합니다.")
    }

    private func notice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
