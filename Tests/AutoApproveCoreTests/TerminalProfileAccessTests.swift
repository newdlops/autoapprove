import Foundation
import ApplicationServices
import AutoApproveCore

private final class ProfileAXFixture {
    let pid:Int32=1009001
    let app=AXUIElementCreateApplication(1009001),window=AXUIElementCreateApplication(1009002)
    let bar=AXUIElementCreateApplication(1009003),a=AXUIElementCreateApplication(1009004),b=AXUIElementCreateApplication(1009005)
    var readStatus:AXError = .success,actionStatus:AXError = .success
    var owns=true,foreground=true,selected=0,reads=0
    var delayedSelectionReads=0,pendingSelection:Int?
    var actions:[String]=[]
    var services:TerminalNativeTabReader.Services {
        .init(ownsProcess:{pid,bundle in self.owns && pid==self.pid && bundle=="com.apple.Terminal"},read:{element,name in
            self.reads+=1
            guard self.readStatus == .success else {return (self.readStatus,nil)}
            if CFEqual(element,self.app) {
                if name==kAXFocusedWindowAttribute {return (.success,self.window)}
                if name==kAXWindowsAttribute {return (.success,[self.window] as CFArray)}
            }
            if CFEqual(element,self.window),name==kAXChildrenAttribute {return (.success,[self.bar] as CFArray)}
            if CFEqual(element,self.bar) {
                if name==kAXRoleAttribute {return (.success,kAXTabGroupRole as CFString)}
                if name==kAXTabsAttribute {return (.success,[self.a,self.b] as CFArray)}
                if name==kAXValueAttribute {
                    if let pending=self.pendingSelection {
                        if self.delayedSelectionReads==0 {self.selected=pending;self.pendingSelection=nil}
                        else {self.delayedSelectionReads-=1}
                    }
                    return (.success,self.selected==0 ? self.a:self.b)
                }
                if name==kAXWindowAttribute {return (.success,self.window)}
            }
            return (.attributeUnsupported,nil)
        },action:{element,name in
            self.actions.append(name)
            guard self.actionStatus == .success else {return self.actionStatus}
            if name==kAXPressAction {
                let target:Int
                if CFEqual(element,self.a) {target=0}
                else if CFEqual(element,self.b) {target=1}
                else {return .invalidUIElement}
                if self.delayedSelectionReads>0 {self.pendingSelection=target}
                else {self.selected=target}
            }
            return .success
        },foreground:{self.foreground && $0==self.pid})
    }
    func reader()->TerminalNativeTabReader {.init(ownerPID:pid,bundleID:"com.apple.Terminal",services:services)}
}

extension ApprovalTests {
    func testTerminalProfileAccessUsesAuthoritativeReadAndActionReplies() throws {
        let fixture=ProfileAXFixture(),reader=fixture.reader()
        let original=try reader.groups()
        try expectEqual(original.count,1);try expectEqual(original[0].tabs.count,2)
        fixture.selected=1
        try reader.restore(original)
        try expectEqual(fixture.selected,0)
        try expectEqual(fixture.actions.filter {$0==kAXPressAction}.count,1)
        try expect(fixture.reads>0)
        let delayed=ProfileAXFixture(),other=delayed.reader(),baseline=try other.groups()
        delayed.selected=1;delayed.delayedSelectionReads=3
        try other.restore(baseline)
        try expectEqual(delayed.selected,0);try expectEqual(delayed.actions.filter {$0==kAXPressAction}.count,1,"Wait for AX selection reflection without pressing a second time")
    }

    func testTerminalProfileAccessDistinguishesDeniedUnreadableAndMissingTree() throws {
        for status in [AXError.apiDisabled,.cannotComplete,.attributeUnsupported] {
            let fixture=ProfileAXFixture();fixture.readStatus=status
            var caught:Error?
            do {_ = try fixture.reader().groups()} catch {caught=error}
            try expect(caught != nil,"Unreadable AX windows must not silently become separate saved windows")
            try expectEqual(caught as? TerminalProfileAccessError,status == .apiDisabled ? .accessibilityDenied:nil)
            if status == .apiDisabled {
                try expect(caught!.localizedDescription.contains("이미 허용했다면"))
                try expect(!caught!.localizedDescription.contains("Terminal을 연"))
            } else {try expect(!caught!.localizedDescription.contains("손쉬운 사용"),"A read timeout is not permission denial")}
            try expect(fixture.actions.isEmpty)
        }
        try expect(!TerminalProfileAccessError.terminalNotRunning.localizedDescription.contains("손쉬운 사용"))
    }

    func testTerminalProfileAccessRevocationAndOwnerFocusChangesBlockActions() throws {
        let revoked=ProfileAXFixture(),reader=revoked.reader(),original=try reader.groups()
        revoked.selected=1;revoked.actionStatus = .apiDisabled
        var denied:Error?
        do {try reader.restore(original)} catch {denied=error}
        try expectEqual(denied as? TerminalProfileAccessError,.accessibilityDenied)
        try expectEqual(revoked.actions.filter {$0==kAXPressAction}.count,1)
        try expectEqual(revoked.selected,1);try expect(!revoked.actions.contains(kAXRaiseAction))
        for ownerChanged in [true,false] {
            let changed=ProfileAXFixture(),other=changed.reader(),state=try other.groups()
            changed.selected=1
            if ownerChanged {changed.owns=false} else {changed.foreground=false}
            var failure:Error?
            do {try other.restore(state)} catch {failure=error}
            try expect(failure != nil);try expect(changed.actions.isEmpty)
        }
    }
}
