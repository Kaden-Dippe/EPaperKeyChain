#include <Arduino.h>
#include <Inkplate.h>
#include <NimBLEDevice.h>
#include <CustomCallbacks.h>
#include <LittleFS.h>

// All vars declared outside of functions are static and persist for the lifetime of the program.
// static allocates memory for the CustomServerCallbacks object at compile time, ensuring it persists for the lifetime of the program.
Inkplate display; 

CustomServerCallbacks customServerCallbacks;

// This is the name that will show up on the phone when scanning for BLE devices.
constexpr char DEVICE_NAME[] = "Epaper Keychain";

// BLE servers can have multiple services. The service is like a container for characteristics, which represent different types of data.
constexpr char SERVICE_UUID[] =
    "a6b10001-7a4d-4c39-9f60-8c835f21e801";

// Represents the characteristic that will be used to send data to the phone. The phone will read this characteristic to get the data.
// You can create different characterstics for different data; e.g image data, text data.
constexpr char CHARACTERISTIC_UUID[] =
    "a6b10002-7a4d-4c39-9f60-8c835f21e801";

[[noreturn]] void haltStartup(const char* message) {
    Serial.println(message);
    Serial.flush();

    esp_deep_sleep_start();

    // defensive fallback if deep sleep fails.
    while (true) {
        delay(1000);
    }
}

void setup() {
    // 1. Initialize the serial monitor for debugging
    Serial.begin(115200);
    Serial.println("Booting up...");

    // Initialize the filesystem before creating hardware or BLE resources.
    if (!LittleFS.begin()) {
        haltStartup("Failed to initialize LittleFS");
    }

    // 2. Initialize the e-paper hardware registers
    display.begin();
    
    // 3. Clear the frame buffer in RAM
    display.clearDisplay();

    // 4. Configure text properties
    display.setTextColor(BLACK, WHITE);
    display.setTextSize(3);
    
    // 5. Write to the RAM buffer (X, Y coordinates)
    display.setCursor(10, 50);
    display.print("Starting BLE server");

    // 6. Push the RAM buffer to the physical screen via SPI
    display.display();
    
    Serial.println("Screen updated successfully.");

    // start the BLE server
    // should do null checks for these in future.
    NimBLEDevice::init(DEVICE_NAME);
    
    NimBLEServer *pServer = NimBLEDevice::createServer();
    
    pServer->setCallbacks(&customServerCallbacks);
    NimBLEService *pService = pServer->createService(SERVICE_UUID);
    NimBLECharacteristic *pCharacteristic = pService->createCharacteristic(CHARACTERISTIC_UUID);
    
    //pServer->start();
    // Note: compiler says service->start() is deprecated, but leaving this in for now.
    pService->start();
    pCharacteristic->setValue("Hello BLE");
    
    NimBLEAdvertising *pAdvertising = NimBLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(SERVICE_UUID); // advertise the UUID of our service
    pAdvertising->setName(DEVICE_NAME); // advertise the device name
    pAdvertising->start(); 

    Serial.println("BLE server started");

    // 3. Cut the power to the main CPU and RAM
    //esp_deep_sleep_start();
    
    // Anything written after esp_deep_sleep_start() will never execute.
    //Serial.println("This will never print.");
}

void loop() {
  // put your main code here, to run repeatedly:
}