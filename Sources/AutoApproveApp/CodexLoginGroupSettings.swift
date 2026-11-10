import SwiftUI
import AutoApproveCore

@MainActor struct CodexLoginGroupSettings:View {
    let groups:[CodexLoginGroup]
    let rename:(UUID,String) async throws->CodexLoginGroup
    @State private var selected:UUID?
    @State private var name=""
    @State private var saving=false
    @State private var error:String?
    @State private var saved=false
    private var current:CodexLoginGroup? {groups.first{$0.id==selected}}
    private var valid:Bool {!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && name.count<=80}
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            if groups.isEmpty {
                Text("추가한 로그인 그룹이 없습니다. ‘새 로그인 그룹’에서 별도 계정의 그룹을 만들 수 있습니다.")
                    .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            } else {
                Picker("설정할 그룹",selection:$selected) {
                    ForEach(groups){group in Text(group.name).lineLimit(1).help(group.name).tag(Optional(group.id))}
                }.disabled(saving)
                if let current {
                    Text("그룹 이름").font(.callout.weight(.medium))
                    HStack(alignment:.firstTextBaseline,spacing:8) {
                        TextField("그룹 이름",text:$name).textFieldStyle(.roundedBorder).accessibilityLabel("변경할 그룹 이름")
                            .disabled(saving).onSubmit{save()}
                        Button("이름 저장",action:save).disabled(saving || !valid || name==current.name)
                    }
                    Text("1~80자 · 이름을 바꿔도 로그인과 연결된 대화는 유지됩니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Text(current.home).font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    if saving {HStack{ProgressView().controlSize(.small);Text("그룹 이름을 저장하는 중…")}.font(.caption)}
                    if let error {Label(error,systemImage:"exclamationmark.circle").foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
                    if saved {Label("그룹 이름을 저장했습니다.",systemImage:"checkmark.circle").font(.caption)}
                }
            }
        }.onAppear{selectCurrent()}
            .onChange(of:selected){_,_ in selectCurrent()}
            .onChange(of:groups){_,_ in
                if !groups.contains(where:{$0.id==selected}) {selected=groups.first?.id;selectCurrent()}
            }
            .onChange(of:name){_,_ in error=nil;if name != current?.name{saved=false}}
    }
    private func selectCurrent() {
        if selected==nil {selected=groups.first?.id}
        name=current?.name ?? "";error=nil;saved=false
    }
    private func save() {
        guard !saving,valid,let current,name != current.name else{return}
        saving=true;error=nil;saved=false
        let value=name,id=current.id
        Task {
            defer{saving=false}
            do {let group=try await rename(id,value);if selected==id{name=group.name;saved=true}}
            catch {if selected==id{self.error=error.localizedDescription}}
        }
    }
}
