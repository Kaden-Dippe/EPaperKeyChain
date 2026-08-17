#include <Arduino.h>
#include <Inkplate.h>
#include <NimBLEDevice.h>
#include <CustomCallbacks.h>
#include <LittleFS.h>
#include <TransferState.h>

// All vars declared outside of functions are static and persist for the lifetime of the program.
// static allocates memory for the CustomServerCallbacks object at compile time, ensuring it persists for the lifetime of the program.
Inkplate display; 

ServerCallbacks customServerCallbacks;

// This is the name that will show up on the phone when scanning for BLE devices.
constexpr char DEVICE_NAME[] = "Epaper Keychain";

// BLE servers can have multiple services. The service is like a container for characteristics, which represent different types of data.
constexpr char SERVICE_UUID[] =
    "a6b10001-7a4d-4c39-9f60-8c835f21e801";

// Represents the Control characteristic. More details in CustomCallbacks.h.
constexpr char CONTROL_CHARACTERISTIC_UUID[] =
    "a6b10002-7a4d-4c39-9f60-8c835f21e801";

// Represents the Image characteristic. More details in CustomCallbacks.h.
constexpr char IMAGE_CHARACTERISTIC_UUID[] =
    "c3dcab57-1604-4c90-a351-1a601ef6d806";

// the dimensions of the e-paper display.
constexpr size_t WIDTH = 212;
constexpr size_t HEIGHT = 104;

// 4 pixels per byte
// each pixel is 2 bits: needs to represent 3 values - black, white, red.
constexpr size_t ROW_BYTES = WIDTH / 4;


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
    NimBLECharacteristic *pControlCharacteristic = pService->createCharacteristic(CONTROL_CHARACTERISTIC_UUID);
    NimBLECharacteristic *pImageCharacteristic = pService->createCharacteristic(IMAGE_CHARACTERISTIC_UUID);

    //pServer->start();
    // Note: compiler says service->start() is deprecated, but leaving this in for now.
    pService->start();
    
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

/*
@breif Displays the image on the e-paper display
*/
void loop() {
    TransferState state = currentState.load();

    if (state == TransferState::DISPLAYING) {
        Serial.println("Displaying image...");
        //displayImageFromFile();
        currentState.store(TransferState::READY);
    }
}

bool displayImageFromFile() {
    // load the image from the file
    imageFile = LittleFS.open(FILE_PATH, "r");
    if (imageFile == nullptr)

    // clear the display

    // read each byte from the file, and fill the frame buffer with the correct value

    // display the image

}