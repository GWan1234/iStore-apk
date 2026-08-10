#ifndef LIBSSH2_SERIALSESSION_H
#define LIBSSH2_SERIALSESSION_H

#include "protocol/Session.h"
#include <thread>
#include <atomic>
#include <vector>
#include <mutex>
#include <map>
#include <queue>
#include <string>
#include <fcntl.h> // For fcntl() and file control operations
#include <termios.h> // For terminal I/O interfaces
#include <unistd.h> // For POSIX API like close()
#include <sys/select.h> // For select() and fd_set
#include <errno.h> // For errno

// Serial error codes
enum SerialError {
    SERIAL_OK = 0,
    SERIAL_OPEN_FAILED,
    SERIAL_CONFIG_FAILED,
    SERIAL_INVALID_PARAMS,
    SERIAL_TIMEOUT,
    SERIAL_SEND_FAILED,
    SERIAL_RECEIVE_FAILED
};

// Error information structure
struct SerialErrorInfo {
    SerialError code;
    std::string message;
};

// Parity options
enum SerialParity {
    PARITY_NONE,
    PARITY_ODD,
    PARITY_EVEN,
    PARITY_MARK,
    PARITY_SPACE
};

// Flow control options
enum SerialFlowControl {
    FLOW_NONE,
    FLOW_XONXOFF,
    FLOW_RTSCTS,
    FLOW_DSRDTR
};

// Serial session state
class SerialSession : public Session {
public:
    SerialSession();
    ~SerialSession() override;

    bool openConnect(const std::string& napiInput) override;
    bool disconnect() override;
    bool sendData(const std::string& command) override;

    // Get last error information
    SerialErrorInfo getLastError() const { return lastError; }

    // --- 新增：实现基类纯虚函数的 override ---
    bool setLogging(int fd, int logType, int existOperation, bool includeHeader = false, bool omitKnownPassword = false, bool omitSessionData = false) override;
    bool resizeTerminal(int width, int height) override;
    // -----------------------------------------

private:
    // Serial port handling
    void receiveLoop(); // Background thread function for receiving data
    bool configureSerialPort(int baudRate, int dataBits, int stopBits, SerialParity parity, SerialFlowControl flowControl);
    
    // Helper methods
    void setError(SerialError code, const std::string& message);
    
    // Serial port file descriptor
    int serialFd = -1;
    std::string serialDevice;
    
    // Original terminal settings to restore on close
    struct termios originalTios;
    bool settingsSaved = false;

    // Threading
    std::thread receiveThread;
    std::atomic<bool> running{false};
    std::mutex serialMutex; // Mutex to protect serial port access

    // Error handling
    SerialErrorInfo lastError = {SERIAL_OK, ""};
    
    // Serial port configuration
    int baudRate = 9600;
    int dataBits = 8;
    int stopBits = 1;
    SerialParity parity = PARITY_NONE;
    SerialFlowControl flowControl = FLOW_NONE;
};

#endif // LIBSSH2_SERIALSESSION_H
