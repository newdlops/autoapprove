import Foundation

/// Version of the assets that this process actually ships, independent of discovery protocol 1.
public struct RemoteWebVersion: Codable, Equatable, Comparable, Sendable {
    public var version: String
    public var build: Int
    public var api: Int
    public init(version: String, build: Int, api: Int = 1) {
        self.version = version; self.build = build; self.api = api
    }
    private var numbers: [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let number = Int(part) else { return nil }
            result.append(number)
        }
        return result
    }
    // Only compatible stable releases participate; unknown/preview metadata never displaces one.
    public var isCompatible: Bool { api == 1 && numbers != nil && (1...1_000_000).contains(build) }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let left = lhs.numbers ?? [], right = rhs.numbers ?? []
        if left != right { return left.lexicographicallyPrecedes(right) }
        return lhs.build < rhs.build
    }
    public static let current: Self? = {
        let file = "AutoApprove_AutoApproveCore.bundle/RemoteWeb/web-version.json"
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(file),
            executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/" + file)]
        for candidate in candidates.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: candidate), let value = try? JSONDecoder().decode(Self.self, from: data), value.isCompatible { return value }
        }
        // SPM's accessor may reference the build machine. Packaged apps/helpers
        // must return above before evaluating it, including after relocation.
        guard let url = Bundle.module.url(forResource: "web-version", withExtension: "json", subdirectory: "RemoteWeb"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data), value.isCompatible else { return nil }
        return value
    }()
}

public struct RemoteWebGateway: Codable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    public var release: RemoteWebVersion
}
