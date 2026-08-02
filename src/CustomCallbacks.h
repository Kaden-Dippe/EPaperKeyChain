#include <NimBLEDevice.h>
#include <Arduino.h>
#include <LittleFS.h>
#include <TransferState.h>


/*
* Dev notes on RTOS BLE:
* The NimBLE library runs on a single, dedicated FreeRTOS task acting like a single threaded dispatcher.
* Everything transmitted over the air is sent in order.
* All packets are processed on one queue in the order they were received - thread is blocked until the current callback finishes.
* No need to worry about race conditions between different characteristics.
* Default BLE MTU is 23 bytes.
*/

/*
* @brief Custom server callbacks for handling BLE events on the control characteristic.
*/
class ControlCallbacks : public NimBLEServerCallbacks {
public:
    uint8_t START_BYTE = 0xAA;
    uint8_t END_BYTE = 0xBB;

    void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override {
        Serial.println("Phone connected to Control characteristic!");
    }

    void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override {
        Serial.println("Phone disconnected from control characteristic, restarting advertising...");
        
        // This tells the BLE radio to start broadcasting our UUIDs again
        NimBLEDevice::startAdvertising();
    }

    void onWrite(NimBLECharacteristic* pCharacteristic) {

        // strings are just 1 byte per character.
        NimBLEAttValue rxBytes = pCharacteristic->getValue();
        if (rxBytes.size() > 0) {
            uint8_t byteValue = rxBytes[0];
            Serial.print("Received data: ");
            Serial.println(byteValue, HEX);

            if (byteValue == START_BYTE) {
                switch (currentState.load()) {
                    case TransferState::READY:
                        Serial.println("Start byte received, starting image transfer.");
                        currentState.store(TransferState::CLIENT_TRANSFERRING);
                        // open image pointer.
                        break;
                    case TransferState::CLIENT_TRANSFERRING:
                        Serial.println("Start byte received, but transfer is already in progress.");
                        currentState.store(TransferState::READY);
                        // reset image file to prepare for a new transfer
                        
                        break;
                    case TransferState::DISPLAYING:
                        Serial.println("Start byte received, but currently displaying an image. Ignoring.");
                        break;
                }
            } else if (byteValue == END_BYTE) {
                Serial.println("End byte received, image transfer complete.");
                // Set the transfer state to DISPLAYING
                TransferState state = TransferState::DISPLAYING;
            }
        } else {
            Serial.println("Received empty data");
        }
    }
};

class CustomCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:

};