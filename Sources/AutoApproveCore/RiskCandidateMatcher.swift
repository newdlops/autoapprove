/// Negative-only Aho–Corasick search for the policy's ASCII candidate literals.
/// The compact table avoids per-character dictionaries and per-request state.
struct RiskCandidateMatcher: Sendable {
    private static let alphabetCount = 29
    private let transitions: [UInt16]

    private static func symbol(_ value: UInt32) -> Int? {
        switch value {
        case 65...90: return Int(value - 65)
        case 97...122: return Int(value - 97)
        case 45: return 26
        case 47: return 27
        case 95: return 28
        default: return nil
        }
    }

    init(words: [String]) {
        struct State {
            var edges = [Int](repeating: 0, count: RiskCandidateMatcher.alphabetCount)
            var failure = 0
            var accepting = false
        }
        guard !words.isEmpty else { transitions = []; return }
        var states = [State()]
        for word in words {
            guard !word.isEmpty else { transitions = []; return }
            var state = 0
            for scalar in word.unicodeScalars {
                guard let symbol = Self.symbol(scalar.value) else { transitions = []; return }
                if states[state].edges[symbol] == 0 {
                    guard (states.count + 1) * Self.alphabetCount < Int(UInt16.max) else { transitions = []; return }
                    let next = states.count
                    states.append(State()); states[state].edges[symbol] = next
                }
                state = states[state].edges[symbol]
            }
            states[state].accepting = true
        }
        var queue = states[0].edges.filter { $0 != 0 }, cursor = 0
        while cursor < queue.count {
            let parent = queue[cursor]; cursor += 1
            for symbol in 0..<Self.alphabetCount {
                let child = states[parent].edges[symbol]
                let failure = states[states[parent].failure].edges[symbol]
                if child == 0 { states[parent].edges[symbol] = failure }
                else {
                    states[child].failure = failure
                    states[child].accepting = states[child].accepting || states[failure].accepting
                    queue.append(child)
                }
            }
        }
        transitions = states.flatMap { state in
            state.edges.map { next in states[next].accepting ? UInt16.max : UInt16(next * Self.alphabetCount) }
        }
    }

    /// Receives exactly the normalized, whitespace-compacted regex input.
    /// nil retains ICU's full folding for expanding/non-ASCII mappings and for
    /// scalars unknown to Swift's Unicode tables. Only false skips the regexes.
    func contains(_ text: String) -> Bool? {
        guard !transitions.isEmpty else { return nil }
        var offset = 0
        for scalar in text.unicodeScalars {
            if !scalar.isASCII {
                if scalar.properties.changesWhenCaseFolded || scalar.properties.generalCategory == .unassigned { return nil }
                offset = 0; continue
            }
            guard let symbol = Self.symbol(scalar.value) else { offset = 0; continue }
            let next = transitions[offset + symbol]
            if next == UInt16.max { return true }
            offset = Int(next)
        }
        return false
    }
}
