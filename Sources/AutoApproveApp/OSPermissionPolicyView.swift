import SwiftUI
import AutoApproveCore

struct OSPermissionPolicyView:View {
    let session:AgentSession
    let status:OSPermissionMonitorStatus?
    let paused:Bool
    var setAllowed:(([OSPermissionKind]) throws -> Void)?
    var assign:((String,String,Bool) throws -> Void)?
    var remove:((String) throws -> Void)?
    var acknowledge:((String,String) throws -> Void)?
    var initiallyExpanded=false
    @State private var expanded=false
    @State private var error:String?
    private var policy:OSPermissionPolicy {session.osPermissionPolicy ?? .init()}
    private var requests:[OSPermissionRequest] {(status?.requests ?? []).filter {$0.sessionID==nil || $0.sessionID==session.id}.filter {$0.phase != .resolved}.prefix(12).map {$0}}
    private func perform(_ work:() throws -> Void) {do {try work();error=nil} catch {self.error=error.localizedDescription}}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("OS 권한 정책").font(.headline)
            Text(policy.isEnabled ? "이 세션에서 \(policy.allowed.count)종류 허용 · 등록 앱 \(policy.targets.count)개":"직접 확인 · 이 세션의 OS 권한 자동 승인이 꺼져 있습니다.")
                .font(.callout).fixedSize(horizontal:false,vertical:true)
            Text(status?.detail ?? "OS 권한 연결을 확인하고 있습니다.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if paused {Text("전체 일시정지 중에는 OS 권한을 조작하지 않습니다.").font(.caption).foregroundStyle(.orange)}
            ForEach(requests) {request in
                VStack(alignment:.leading,spacing:8) {
                    Text("\(request.requester?.name ?? "요청 앱 미확인") · \(request.kind.title)").font(.callout.weight(.semibold)).fixedSize(horizontal:false,vertical:true)
                    Text(request.detail).font(.callout).fixedSize(horizontal:false,vertical:true)
                    if let target=request.requester {Text(target.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
                    DisclosureGroup("OS 요청 내용") {Text(request.content).font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
                    if request.managementApp != true,request.phase == .waiting,request.action != .manual,!policy.allowed.contains(request.kind) {
                        Button("이 세션에서 \(request.kind.title) 허용") {perform {try setAllowed?(policy.allowed+[request.kind])}}
                            .disabled(setAllowed==nil || session.phase == .ended)
                    }
                    if request.managementApp != true,request.phase == .waiting,request.sessionID==nil,let target=request.requester {
                        ViewThatFits(in:.horizontal) {
                            HStack {assignmentButtons(request,target:target)}
                            VStack(alignment:.leading,spacing:8) {assignmentButtons(request,target:target)}
                        }
                    }
                    if request.managementApp != true,request.sessionID==session.id,request.phase != .approving {
                        Button("Mac에서 처리 완료로 표시") {perform {try acknowledge?(request.id,request.immutableToken)}}.disabled(acknowledge==nil)
                            .help("OS 설정이나 원래 앱에서 결과를 직접 확인한 뒤 이 대기 표시를 닫습니다. 권한을 부여하는 버튼은 아닙니다.")
                    }
                }.padding(.vertical,8)
            }
            DisclosureGroup("허용할 권한·등록 앱",isExpanded:$expanded) {
                VStack(alignment:.leading,spacing:12) {
                    Text("선택한 권한은 이 세션에 등록한 앱 또는 직접 연결한 현재 요청에 적용됩니다. OS가 부여한 권한은 이 정책을 꺼도 자동 회수되지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:190),alignment:.leading)],alignment:.leading,spacing:8) {
                        ForEach(OSPermissionKind.automaticCases,id:\.self) {kind in
                            Toggle(kind.title,isOn:Binding(get:{policy.allowed.contains(kind)},set:{enabled in
                                perform {try setAllowed?(enabled ? policy.allowed+[kind]:policy.allowed.filter {$0 != kind})}
                            })).toggleStyle(.checkbox).disabled(setAllowed==nil || session.phase == .ended)
                                .help("\(session.project) 세션의 등록 앱에 대한 \(kind.title) 자동 승인을 결정합니다.")
                        }
                    }
                    if policy.targets.isEmpty {Text("등록한 앱이 없습니다. OS 권한 요청이 나타나면 앱과 내용을 확인해 이 세션에 등록하세요.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                    ForEach(policy.targets) {target in
                        VStack(alignment:.leading,spacing:4) {
                            HStack {Text(target.name).font(.callout.weight(.medium));Spacer();Button("등록 해제") {perform {try remove?(target.id)}}.disabled(remove==nil)}
                            Text(target.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        }
                    }
                }.padding(.top,8)
            }
            if let error {Label(error,systemImage:"exclamationmark.triangle").font(.callout).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true).accessibilityLabel("OS 권한 오류: "+error)}
        }
        .onAppear {expanded=initiallyExpanded}
    }
    @ViewBuilder private func assignmentButtons(_ request:OSPermissionRequest,target:OSPermissionTarget)->some View {
        Button("이 요청만 이 세션에 연결") {perform {try assign?(request.id,request.immutableToken,false)}}.disabled(assign==nil)
        if !target.isSharedController {
            Button("이 앱을 이 세션에 등록") {perform {try assign?(request.id,request.immutableToken,true)}}.disabled(assign==nil)
        }
    }
}
