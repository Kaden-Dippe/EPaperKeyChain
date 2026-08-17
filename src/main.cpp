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

// The characteristic callbacks have to outlive setup(), same as the server
// callbacks above, so they live here rather than as locals.
ControlCharacteristicCallbacks controlCallbacks;
ImageCharacteristicCallbacks imageCallbacks;

// Definitions for the two declarations in TransferState.h. The header only
// declares them with extern, which tells the compiler their type but creates
// no storage; without these lines the build compiles and then fails to link
// with "undefined reference to currentState". They belong in exactly one
// translation unit, and this is the only one.
std::atomic<TransferState> currentState{TransferState::READY};
File imageFile;

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

// The exact size the phone sends: 53 bytes per row, 104 rows.
constexpr size_t IMAGE_BYTES = ROW_BYTES * HEIGHT;

// Reads the saved image back off the filesystem and pushes it to the panel.
// Defined below loop(); declared here because this is a .cpp, which gets no
// automatic prototypes the way an .ino would.
bool displayImageFromFile();


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
    // NOTIFY is what lets the server push status bytes back. Without it NimBLE
    // creates no CCCD descriptor, the phone's subscribe request fails, and the
    // connection never completes - so every notify() below would go nowhere.
    NimBLECharacteristic *pControlCharacteristic = pService->createCharacteristic(
        CONTROL_CHARACTERISTIC_UUID,
        NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY);

    // WRITE rather than WRITE_NR: the client relies on the acknowledgement the
    // stack sends after each packet to pace itself against our flash writes.
    NimBLECharacteristic *pImageCharacteristic = pService->createCharacteristic(
        IMAGE_CHARACTERISTIC_UUID,
        NIMBLE_PROPERTY::WRITE);

    // Without these the callback classes never run: writes would land in the
    // characteristic's value buffer and nothing would open a file or reply.
    pControlCharacteristic->setCallbacks(&controlCallbacks);
    pImageCharacteristic->setCallbacks(&imageCallbacks);

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

        if (displayImageFromFile()) {
            Serial.println("Display updated.");
        } else {
            Serial.println("Display update failed; leaving the panel as it is.");
        }

        // READY either way: a bad file should not wedge the board into a state
        // where it refuses every future transfer.
        currentState.store(TransferState::READY);
    }
}

/*
@brief Reads the saved image back and draws it on the panel.
@details Undoes the packing the phone applies: four pixels per byte, two bits
each, most significant bits first, so the left-most pixel of a group sits in
bits 7-6. The 2-bit codes are the same values the Inkplate driver uses for its
colours, which is why the mapping below is a straight pass-through.
@return true if the whole file was read and drawn, false if it was missing,
the wrong size, or truncated.
*/
bool displayImageFromFile() {
    // load the image from the file
    imageFile = LittleFS.open(FILE_PATH, "r");
    if (!imageFile) {
        Serial.println("No image file to display.");
        return false;
    }

    // A short or oversized file means a transfer went wrong; drawing it would
    // smear whatever bytes did arrive across the panel.
    if (imageFile.size() != IMAGE_BYTES) {
        Serial.print("Image file is ");
        Serial.print(imageFile.size());
        Serial.print(" bytes, expected ");
        Serial.println(IMAGE_BYTES);
        imageFile.close();
        return false;
    }

    // clear the display
    display.clearDisplay();

    // read each byte from the file, and fill the frame buffer with the correct value
    uint8_t row[ROW_BYTES];
    for (size_t y = 0; y < HEIGHT; y++) {
        const size_t bytesRead = imageFile.read(row, ROW_BYTES);
        if (bytesRead != ROW_BYTES) {
            Serial.print("Ran out of data on row ");
            Serial.println(y);
            imageFile.close();
            return false;
        }

        for (size_t byteIndex = 0; byteIndex < ROW_BYTES; byteIndex++) {
            const uint8_t packed = row[byteIndex];

            for (size_t offset = 0; offset < 4; offset++) {
                // Pixel 0 occupies bits 7-6, pixel 1 bits 5-4, and so on.
                const uint8_t code = (packed >> (6 - 2 * offset)) & 0b11;
                const size_t x = byteIndex * 4 + offset;

                uint8_t colour;
                switch (code) {
                    case 0b00: colour = BLACK; break;
                    case 0b01: colour = WHITE; break;
                    case 0b10: colour = RED; break;
                    // 0b11 is unused by the panel; treat it as blank paper
                    // rather than drawing something undefined.
                    default:   colour = WHITE; break;
                }

                display.drawPixel(static_cast<int16_t>(x), static_cast<int16_t>(y), colour);
            }
        }
    }

    imageFile.close();

    // display the image
    display.display();
    return true;
}