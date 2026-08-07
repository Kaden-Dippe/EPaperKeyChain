// note: should understand how c++ compiles better and look back at this.
#pragma once
#include <atomic>
#include <LittleFS.h>

/*
 * @brief The state of the image transfer process between client and the mcu.
 */
enum class TransferState {
    READY,
    CLIENT_TRANSFERRING,
    DISPLAYING
};

// The current state of the image transfer process.
extern std::atomic<TransferState> currentState;

// The image to be displayed on the e-paper display.
// Only the image characteristic writes to this file, so no need for thread safety.
extern File imageFile;

extern constexpr char FILE_PATH[] = "image.bin";