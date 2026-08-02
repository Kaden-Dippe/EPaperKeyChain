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

extern std::atomic<TransferState> currentState;
extern File imageFile;