import CoreBluetooth
import Foundation

/// The wire contract with the ESP32 firmware.
///
/// UUIDs and the advertised name mirror `src/main.cpp` in this repository.
enum NecklaceProtocol {

    /// Name the firmware advertises (`DEVICE_NAME` in `src/main.cpp`).
    static let deviceName = "Epaper Keychain"

    static let serviceUUID = CBUUID(string: "A6B10001-7A4D-4C39-9F60-8C835F21E801")

    /// Write + notify. Carries the START/END commands and the status replies.
    static let controlCharacteristicUUID = CBUUID(string: "A6B10002-7A4D-4C39-9F60-8C835F21E801")

    /// Write with response only. Image chunks are paced by the ATT-level
    /// acknowledgement, not by an application notification, which is what
    /// keeps the firmware's flash writes from falling behind.
    static let imageCharacteristicUUID = CBUUID(string: "C3DCAB57-1604-4C90-A351-1A601EF6D806")

    /// Commands the app writes to the control characteristic.
    enum Command: UInt8 {
        case start = 0xAA
        case end   = 0xBB
    }

    /// Status bytes the firmware notifies back on the control characteristic.
    enum Status: Equatable {
        case ok
        case error
        case busy

        init?(byte: UInt8) {
            switch byte {
            case 0x01: self = .ok
            case 0x02: self = .error
            case 0x03: self = .busy

            // The firmware currently in `src/CustomCallbacks.h` still uses its
            // original status codes (0xCC / 0xDD, with no distinct BUSY byte).
            // Accepting both keeps the app working against boards that haven't
            // been reflashed yet; drop these two cases once the firmware moves
            // to 0x01/0x02/0x03.
            case 0xCC: self = .ok
            case 0xDD: self = .error

            default: return nil
            }
        }
    }

    /// How long to wait for a status notification after START or END.
    static let controlTimeout: TimeInterval = 5

    /// How long to wait for the ATT write response on a single image chunk.
    /// Longer than the control timeout because the firmware is writing to
    /// flash between packets.
    static let chunkTimeout: TimeInterval = 10

    /// How long to wait for the peripheral to show up while scanning.
    static let scanTimeout: TimeInterval = 15

    /// How long to allow for connect + service discovery + subscribing.
    static let connectTimeout: TimeInterval = 20
}
