#include <Arduino.h>
#include <Inkplate.h>

// put function declarations here:
int myFunction(int, int);

Inkplate display; 

void setup() {
    // 1. Initialize the serial monitor for debugging
    Serial.begin(115200);
    Serial.println("Booting up...");

    // 2. Initialize the e-paper hardware registers
    display.begin();
    
    // 3. Clear the frame buffer in RAM
    display.clearDisplay();

    // 4. Configure text properties
    display.setTextColor(BLACK, WHITE);
    display.setTextSize(3);
    
    // 5. Write to the RAM buffer (X, Y coordinates)
    display.setCursor(10, 50);
    display.print("Hello, World!");

    // 6. Push the RAM buffer to the physical screen via SPI
    display.display();
    
    Serial.println("Screen updated successfully.");

    // 3. Cut the power to the main CPU and RAM
    esp_deep_sleep_start();
    
    // Anything written after esp_deep_sleep_start() will never execute.
    Serial.println("This will never print.");
}

void loop() {
  // put your main code here, to run repeatedly:
}

// put function definitions here:
int myFunction(int x, int y) {
  return x + y;
}