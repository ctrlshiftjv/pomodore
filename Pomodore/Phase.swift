import Foundation

enum Phase: String, CaseIterable, Sendable {
    case focus
    case shortBreak
    case longBreak

    var isBreak: Bool { self != .focus }

    var name: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }

    /// Three segments have to fit 222pt of popover width, so "Short break" does not.
    var shortName: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short"
        case .longBreak: "Long"
        }
    }
}

extension TimeInterval {
    /// Rounds up, so a fresh 25 minute phase reads 25:00 and 00:00 means the deadline passed.
    var mmss: String {
        let total = max(0, Int(rounded(.up)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
