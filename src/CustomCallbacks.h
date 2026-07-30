#include <NimBLEDevice.h>
#include <Arduino.h>
#include <LittleFS.h>

class CustomServerCallbacks : public NimBLEServerCallbacks {
public:
    void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override {
        Serial.println("Phone connected! (Advertising stops automatically)");
    }

    void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override {
        Serial.println("Phone disconnected! Restarting advertising...");
        
        // This tells the BLE radio to start broadcasting our UUIDs again
        NimBLEDevice::startAdvertising();
    }
};

class CustomCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:

};