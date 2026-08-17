import Foundation

enum NecklaceError: LocalizedError, Equatable {
    case bluetoothOff
    case bluetoothUnauthorized
    case bluetoothUnsupported
    case deviceNotFound
    case connectionFailed(String)
    case missingCharacteristics
    case notConnected
    case deviceBusy
    case deviceRejected
    case unreadableStatus
    case timedOut(String)
    case disconnectedDuringTransfer
    case payloadSizeMismatch(Int)
    case writeFailed(String)
    case superseded

    /// Alert headline. Generic titles make every failure look alike, so each
    /// case names what actually went wrong before the body explains it.
    var alertTitle: String {
        switch self {
        case .bluetoothOff: return "Bluetooth is off"
        case .bluetoothUnauthorized: return "Permission needed"
        case .bluetoothUnsupported: return "Not supported"
        case .deviceNotFound: return "Necklace not found"
        case .connectionFailed, .missingCharacteristics: return "Couldn't connect"
        case .notConnected: return "Not connected"
        case .deviceBusy: return "Just a moment"
        case .deviceRejected, .unreadableStatus: return "Necklace said no"
        case .timedOut: return "No answer"
        case .disconnectedDuringTransfer: return "Connection dropped"
        case .payloadSizeMismatch: return "Wrong image size"
        case .writeFailed: return "Transfer stopped"
        case .superseded: return "Cancelled"
        }
    }

    var errorDescription: String? {
        switch self {
        case .bluetoothOff:
            return "Bluetooth is switched off. Turn it on and try again."
        case .bluetoothUnauthorized:
            return "This app needs Bluetooth permission to talk to your necklace. You can grant it in Settings."
        case .bluetoothUnsupported:
            return "This device doesn't support Bluetooth Low Energy."
        case .deviceNotFound:
            return "Couldn't find your necklace. Make sure it's powered on and nearby."
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .missingCharacteristics:
            return "Connected, but the necklace didn't offer the expected control and image channels."
        case .notConnected:
            return "The necklace isn't connected."
        case .deviceBusy:
            return "The necklace is busy refreshing its screen. Give it a few seconds and try again."
        case .deviceRejected:
            return "The necklace turned down the transfer. Try again in a moment."
        case .unreadableStatus:
            return "The necklace replied with something unexpected."
        case .timedOut(let step):
            return "The necklace stopped responding while \(step)."
        case .disconnectedDuringTransfer:
            return "The connection dropped mid-transfer. Nothing was saved - try again."
        case .payloadSizeMismatch(let count):
            return "Image payload was \(count) bytes; the panel needs exactly \(PanelSpec.payloadByteCount)."
        case .writeFailed(let reason):
            return "A packet failed to send: \(reason)"
        case .superseded:
            return "That request was replaced by a newer one."
        }
    }
}
