import Foundation

extension SessionGroup {
    func canIncludeInSubgroup(_ member: UUID, leader: UUID) -> Bool {
        isLeader(leader) && member != leader && members.contains(where: { $0.id == member }) &&
            !reaches(member, member: leader) && (canDirect(leader, worker: member) || reaches(leader, member: member))
    }

    func managedSubgroups(for leader: UUID, in groups: [Self]) -> Set<UUID> {
        guard isLeader(leader) else { return [] }
        let whole = hasGroupAuthority(leader)
        let children = Dictionary(grouping: groups.filter { $0.subgroupParentID != nil }, by: { $0.subgroupParentID! })
        func manageableChildren(_ parent: UUID) -> [UUID] {
            (children[parent] ?? []).filter { child in
                whole || (!child.members.isEmpty && child.members.allSatisfy { canIncludeInSubgroup($0.id, leader: leader) })
            }.map(\.id)
        }
        var pending = manageableChildren(id)
        var result = Set<UUID>()
        while let next = pending.popLast() {
            guard next != id, result.insert(next).inserted else { continue }
            pending.append(contentsOf: manageableChildren(next))
        }
        return result
    }

    func formingSubgroup(name: String, memberIDs: [UUID], leader: UUID, appointed: UUID?) throws -> Self {
        guard !memberIDs.isEmpty, memberIDs.count <= 128, Set(memberIDs).count == memberIDs.count else {
            throw RemoteHTTPError(400, "memberIDs에는 중복 없이 1~128명의 구성원을 지정해주세요.")
        }
        guard memberIDs.allSatisfy({ canIncludeInSubgroup($0, leader: leader) }) else {
            throw RemoteHTTPError(403, "자신의 하위 구성원으로 서브그룹을 결성할 수 있습니다.")
        }
        let selected = Set(memberIDs)
        guard appointed.map(selected.contains) ?? true else { throw RemoteHTTPError(400, "서브그룹 구성원 중 그룹장을 선택해주세요.") }
        let roster = members.filter { selected.contains($0.id) }.map { member in
            var copy = member
            copy.assignedParentIDs = nil
            copy.parentMemberID = nil
            return copy
        }
        var group = SessionGroup(name: name, members: roster, leaderMemberID: appointed)
        group.parentGroupIDs = [id]
        group.subgroupParentID = id
        return try group.validated()
    }

    static func dissolvingSubgroup(_ group: Self, in groups: [Self]) throws -> [Self] {
        guard let parent = group.subgroupParentID else { throw RemoteHTTPError(403, "해산할 서브그룹을 확인해주세요.") }
        return groups.filter { $0.id != group.id }.map { item in
            var next = item
            let reparent = next.subgroupParentID == group.id
            next.parentGroupIDs.removeAll { $0 == group.id }
            if reparent {
                if !next.parentGroupIDs.contains(parent) { next.parentGroupIDs.append(parent) }
                next.subgroupParentID = parent
            }
            return next
        }
    }
}
