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
        }
    }
}
