import Foundation

@main struct LANInterfaceTypeCheck {
    static func main() throws {
        var cache = RemoteLANInterfaceTypeCache<String>(), reads = 0
        var inventory = ["en0": "wifi", "en7": "ethernet"]
        func load() -> [String: String] { reads += 1; return inventory }
        precondition(cache.resolve(names: [], refresh: false, at: 0, load: load).isEmpty && reads == 0)
        precondition(cache.resolve(names: ["en0"], refresh: false, at: 0, load: load)["en0"] == "wifi" && reads == 1)
        // A second active adapter already classified by that same OS inventory
        // must not trigger another whole-system device enumeration.
        precondition(cache.resolve(names: ["en0", "en7"], refresh: false, at: 1, load: load)["en7"] == "ethernet" && reads == 1)
        inventory["en8"] = "ethernet"
        precondition(cache.resolve(names: ["en8"], refresh: false, at: 2, load: load)["en8"] == "ethernet" && reads == 2)
        // Unknown/unsupported devices are negative-cached only for the same
        // bounded interval; they must never acquire a guessed LAN type.
        precondition(cache.resolve(names: ["en9"], refresh: false, at: 3, load: load)["en9"] == nil && reads == 3)
        precondition(cache.resolve(names: ["en9"], refresh: false, at: 4, load: load)["en9"] == nil && reads == 3)
        inventory.removeValue(forKey: "en0")
        precondition(cache.resolve(names: ["en0"], refresh: true, at: 5, load: load)["en0"] == nil && reads == 4)
        inventory["en0"] = "ethernet"
        precondition(cache.resolve(names: ["en0"], refresh: false, at: 34.999, load: load)["en0"] == nil && reads == 4)
        precondition(cache.resolve(names: ["en0"], refresh: false, at: 35, load: load)["en0"] == "ethernet" && reads == 5)
        print("{\"passed\":9,\"verified\":[\"empty LAN\",\"initial inventory\",\"known second adapter\",\"new adapter\",\"unknown rejection\",\"bounded negative cache\",\"forced path refresh\",\"before expiry\",\"exact expiry reload\"]}")
    }
}
