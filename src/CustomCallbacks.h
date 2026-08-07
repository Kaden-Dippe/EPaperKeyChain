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
class ServerCallbacks : public NimBLEServerCallbacks {
public:
    void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override {
        Serial.println("Phone connected to Control characteristic!");
    }

    void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override {
        Serial.println("Phone disconnected from control characteristic, restarting advertising...");
        
        // This tells the BLE radio to start broadcasting our UUIDs again
        NimBLEDevice::startAdvertising();
    }

    
};

// Client byte code definitions
uint8_t START_BYTE = 0xAA;
uint8_t END_BYTE = 0xBB;

// Server byte code definitions
uint8_t OK_BYTE = 0xCC;
uint8_t ERROR_BYTE = 0xDD;

/*
* @brief Handles starting and stopping the image transfer process.
*/
class ControlCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:

    /*
    * @brief Handles incoming bytes from the server on the control characteristic.
    */
    void onWrite(NimBLECharacteristic* pCharacteristic, NimBLEConnInfo& connInfo) override {

        // strings are just 1 byte per character.
        NimBLEAttValue rxBytes = pCharacteristic->getValue();
        if (rxBytes.size() > 0) {
            uint8_t byteValue = rxBytes[0];
            Serial.print("Received data: ");
            Serial.println(byteValue, HEX);

            if (byteValue == START_BYTE) {
                switch (currentState.load()) {
                    case TransferState::READY:
                        Serial.println("Start byte received.");
                        currentState.store(TransferState::CLIENT_TRANSFERRING);
                        // open image pointer.
                        imageFile = LittleFS.open(FILE_PATH, "w");

                        pCharacteristic->setValue(&OK_BYTE, 1);
                        pCharacteristic->notify();
                        break; 
                    case TransferState::CLIENT_TRANSFERRING:
                        Serial.println("Start byte received, but transfer is already in progress.");
                        currentState.store(TransferState::READY);
                        // reset image file to prepare for a new transfer
                        if (imageFile) {
                            imageFile.close();
                        }
                        pCharacteristic->setValue(&ERROR_BYTE, 1);
                        pCharacteristic->notify();
                        break;
                    case TransferState::DISPLAYING:
                        Serial.println("Start byte received, but currently displaying an image. Ignoring.");
                        pCharacteristic->setValue(&ERROR_BYTE, 1);
                        pCharacteristic->notify();
                        break;
                    default:
                        Serial.println("Start byte received, but in an unknown state. Resetting to READY.");
                        currentState.store(TransferState::READY);
                        pCharacteristic->setValue(&ERROR_BYTE, 1);
                        pCharacteristic->notify();
                        break;
                }
            } else if (byteValue == END_BYTE) {
                Serial.println("End byte received.");
                switch(currentState.load()){
                    case TransferState::READY:
                        Serial.println("End byte received, but no transfer is in progress. Ignoring.");
                        pCharacteristic->setValue(&ERROR_BYTE, 1);
                        pCharacteristic->notify();
                        break;
                    case TransferState::CLIENT_TRANSFERRING:
                        currentState.store(TransferState::DISPLAYING);
                        if (imageFile) {
                            imageFile.close();
                        }
                        pCharacteristic->setValue(&OK_BYTE, 1);
                        pCharacteristic->notify();
                        break;
                    case TransferState::DISPLAYING:
                        Serial.println("End byte received, but currently displaying an image. Ignoring.");
                        pCharacteristic->setValue(&ERROR_BYTE, 1);
                        pCharacteristic->notify();
                        break;
                    default:
                        Serial.println("End byte received, but in an unknown state. Resetting to READY.");
                        currentState.store(TransferState::READY);
                        pCharacteristic->setValue(&ERROR_BYTE, 1);
                        pCharacteristic->notify();
                        break;
                }
            } 
            else {
                Serial.println("Received unknown data byte: " + String(byteValue, HEX));
                pCharacteristic->setValue(&ERROR_BYTE, 1);
                pCharacteristic->notify();
            }
        } else {
            Serial.println("Received empty data");
            pCharacteristic->setValue(&ERROR_BYTE, 1);
            pCharacteristic->notify();
        }
    }
};

/*
* @brief receives and writes image data from the client.
*/
class ImageCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
    public:

        /*
        * @brief Handles incoming bytes from the server on the image characteristic.
        * @details no need to notify client, as client will not be waitin for ack from this characteristic.
        */
        void onWrite(NimBLECharacteristic* pCharacteristic, NimBLEConnInfo& connInfo) override {
            NimBLEAttValue rxBytes = pCharacteristic->getValue();
            if (rxBytes.size() > 0) {
                if (currentState.load() == TransferState::CLIENT_TRANSFERRING) {
                    // Write the received bytes to the image file

                    // write should append to the file.
                    if (imageFile) {
                        imageFile.write(rxBytes.data(), rxBytes.size());
                        Serial.print("Wrote ");
                        Serial.print(rxBytes.size());
                        Serial.println(" bytes to image file.");

                    } else {
                        Serial.println("Error: Image file is not open for writing.");
                    }
                } else {
                    Serial.println("Received data, but not in CLIENT_TRANSFERRING state. Ignoring.");
                }
            } else {
                Serial.println("Received empty data");
            }
        }
};