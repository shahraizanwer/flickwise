// TriggerKey — the right-hand modifiers (and Fn) that can be held to dictate.
// Left and right are told apart by the device-dependent bits of the event flags.
import CoreGraphics

enum TriggerKey: String, Codable, CaseIterable, Identifiable {
    case rightCommand = "right_command"
    case rightOption = "right_option"
    case rightControl = "right_control"
    case rightShift = "right_shift"
    case fn

    var id: String { rawValue }

    var keyCode: Int64 {
        switch self {
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightControl: return 62
        case .rightShift: return 60
        case .fn: return 63
        }
    }

    /// NX_DEVICER*KEYMASK bit that is set while this exact key is down.
    var deviceMask: UInt64 {
        switch self {
        case .rightCommand: return 0x10
        case .rightOption: return 0x40
        case .rightControl: return 0x2000
        case .rightShift: return 0x04
        case .fn: return 0x800000
        }
    }

    /// The generic flag this key also sets (so we can spot *other* modifiers).
    var genericFlag: CGEventFlags {
        switch self {
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .rightControl: return .maskControl
        case .rightShift: return .maskShift
        case .fn: return .maskSecondaryFn
        }
    }

    var title: String {
        switch self {
        case .rightCommand: return "Right ⌘ Command"
        case .rightOption: return "Right ⌥ Option"
        case .rightControl: return "Right ⌃ Control"
        case .rightShift: return "Right ⇧ Shift"
        case .fn: return "Fn / 🌐"
        }
    }

    var short: String {
        switch self {
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .rightControl: return "Right ⌃"
        case .rightShift: return "Right ⇧"
        case .fn: return "Fn"
        }
    }
}
