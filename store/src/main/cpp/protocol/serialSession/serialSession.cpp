#include "serialSession.h"
#include <iostream>
#include <vector>
#include <stdexcept>
#include <hilog/log.h>

// Use cJSON for JSON parsing
extern "C" {
#include "../jsonAnalyse/cJSON.h"
}

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200  // 全局domain宏，标识业务领域
#define LOG_TAG "MY_TAG"   // 全局tag宏，标识模块日志tag

SerialSession::SerialSession() {
    status = SessionStatus::DISCONNECTED;
}

SerialSession::~SerialSession() {
    disconnect();
}

bool SerialSession::openConnect(const std::string& napiInput) {
    OH_LOG_INFO(LOG_APP, "Opening Serial connection with input: %{public}s", napiInput.c_str());

    // Check if already connected or connecting
    if (status != SessionStatus::DISCONNECTED) {
        setError(SERIAL_INVALID_PARAMS, "Session is already connected or connecting");
        return false;
    }

    // Update status to connecting
    status = SessionStatus::CONNECTING;
    if (statusCallback) {
        statusCallback(status);
    }

    cJSON *json = cJSON_Parse(napiInput.c_str());
    if (json == NULL) {
        const char *error_ptr = cJSON_GetErrorPtr();
        std::string errorMsg = "Failed to parse JSON input";
        if (error_ptr != NULL) {
            errorMsg += ": ";
            errorMsg += error_ptr;
        }
        setError(SERIAL_INVALID_PARAMS, errorMsg);
        status = SessionStatus::DISCONNECTED;
        if (statusCallback) statusCallback(status);
        return false;
    }

    // 打印JSON结构
    char *jsonStr = cJSON_Print(json);
    if (jsonStr) {
        OH_LOG_INFO(LOG_APP, "Parsed JSON structure: %{public}s", jsonStr);
        free(jsonStr);
    }

    // Try to get Serial configuration first
    cJSON *serialObj = cJSON_GetObjectItemCaseSensitive(json, "Serial");

    // If Serial object doesn't exist, try to get parameters from Session object
    if (!cJSON_IsObject(serialObj)) {
        OH_LOG_INFO(LOG_APP, "No Serial object found, trying to get parameters from Session object");
        cJSON *sessionObj = cJSON_GetObjectItemCaseSensitive(json, "Session");
        if (!cJSON_IsObject(sessionObj)) {
            setError(SERIAL_INVALID_PARAMS, "Missing or invalid Session object in JSON");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }

        // Extract serial device from serialLine in Session
        cJSON *serialLineJson = cJSON_GetObjectItemCaseSensitive(sessionObj, "serialLine");
        if (!(cJSON_IsString(serialLineJson) && serialLineJson->valuestring != NULL)) {
            setError(SERIAL_INVALID_PARAMS, "Missing or invalid serialLine in Session object");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }
        serialDevice = serialLineJson->valuestring;

        // Extract baud rate from speed in Session
        cJSON *speedJson = cJSON_GetObjectItemCaseSensitive(sessionObj, "speed");
        if (!(cJSON_IsString(speedJson) && speedJson->valuestring != NULL)) {
            setError(SERIAL_INVALID_PARAMS, "Missing or invalid speed in Session object");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }
        baudRate = atoi(speedJson->valuestring);
        if (baudRate <= 0) {
            setError(SERIAL_INVALID_PARAMS, "Invalid baud rate");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }

        // Use default values for other parameters if not available in Session
        dataBits = 8;
        stopBits = 1;
        parity = PARITY_NONE;
        flowControl = FLOW_NONE;

        // Try to get Serial object from allDataKvStore
        OH_LOG_INFO(LOG_APP, "Using default values for dataBits, stopBits, parity, and flowControl");
    } else {
        // Extract serial device
        cJSON *serialLineJson = cJSON_GetObjectItemCaseSensitive(serialObj, "SerialLine");
        if (!(cJSON_IsString(serialLineJson) && serialLineJson->valuestring != NULL)) {
            setError(SERIAL_INVALID_PARAMS, "Missing or invalid SerialLine in JSON");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }
        serialDevice = serialLineJson->valuestring;

        // Extract baud rate
        cJSON *speedJson = cJSON_GetObjectItemCaseSensitive(serialObj, "speed");
        if (!(cJSON_IsString(speedJson) && speedJson->valuestring != NULL)) {
            setError(SERIAL_INVALID_PARAMS, "Missing or invalid speed in JSON");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }
        baudRate = atoi(speedJson->valuestring);
        if (baudRate <= 0) {
            setError(SERIAL_INVALID_PARAMS, "Invalid baud rate");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }

        // Extract data bits
        cJSON *dataBitsJson = cJSON_GetObjectItemCaseSensitive(serialObj, "dataBits");
        if (!(cJSON_IsString(dataBitsJson) && dataBitsJson->valuestring != NULL)) {
            setError(SERIAL_INVALID_PARAMS, "Missing or invalid dataBits in JSON");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }
        dataBits = atoi(dataBitsJson->valuestring);
        if (dataBits < 5 || dataBits > 8) {
            setError(SERIAL_INVALID_PARAMS, "Invalid data bits (must be 5-8)");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }

        // Extract stop bits
        cJSON *stopBitsJson = cJSON_GetObjectItemCaseSensitive(serialObj, "stopBits");
        if (!(cJSON_IsString(stopBitsJson) && stopBitsJson->valuestring != NULL)) {
            setError(SERIAL_INVALID_PARAMS, "Missing or invalid stopBits in JSON");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }
        stopBits = atoi(stopBitsJson->valuestring);
        if (stopBits < 1 || stopBits > 2) {
            setError(SERIAL_INVALID_PARAMS, "Invalid stop bits (must be 1 or 2)");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }

        // Extract parity
        cJSON *parityJson = cJSON_GetObjectItemCaseSensitive(serialObj, "parity");
        if (!(cJSON_IsString(parityJson) && parityJson->valuestring != NULL)) {
            setError(SERIAL_INVALID_PARAMS, "Missing or invalid parity in JSON");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }
        std::string parityStr = parityJson->valuestring;
        if (parityStr == "None") {
            parity = PARITY_NONE;
        } else if (parityStr == "Odd") {
            parity = PARITY_ODD;
        } else if (parityStr == "Even") {
            parity = PARITY_EVEN;
        } else if (parityStr == "Mark") {
            parity = PARITY_MARK;
        } else if (parityStr == "Space") {
            parity = PARITY_SPACE;
        } else {
            setError(SERIAL_INVALID_PARAMS, "Invalid parity value");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }

        // Extract flow control
        cJSON *flowControlJson = cJSON_GetObjectItemCaseSensitive(serialObj, "flowControl");
        if (!(cJSON_IsString(flowControlJson) && flowControlJson->valuestring != NULL)) {
            setError(SERIAL_INVALID_PARAMS, "Missing or invalid flowControl in JSON");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }
        std::string flowControlStr = flowControlJson->valuestring;
        if (flowControlStr == "None") {
            flowControl = FLOW_NONE;
        } else if (flowControlStr == "XON/XOFF") {
            flowControl = FLOW_XONXOFF;
        } else if (flowControlStr == "RTS/CTS") {
            flowControl = FLOW_RTSCTS;
        } else if (flowControlStr == "DSR/DTR") {
            flowControl = FLOW_DSRDTR;
        } else {
            setError(SERIAL_INVALID_PARAMS, "Invalid flow control value");
            cJSON_Delete(json);
            status = SessionStatus::DISCONNECTED;
            if (statusCallback) statusCallback(status);
            return false;
        }
    }

    // Clean up JSON
    cJSON_Delete(json);

    // Open serial port
    OH_LOG_INFO(LOG_APP, "Opening serial port: %{public}s", serialDevice.c_str());
    serialFd = open(serialDevice.c_str(), O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (serialFd < 0) {
        std::string errorMsg = "Failed to open serial port: " + std::string(strerror(errno));
        setError(SERIAL_OPEN_FAILED, errorMsg);
        OH_LOG_ERROR(LOG_APP, "%{public}s", errorMsg.c_str());
        status = SessionStatus::DISCONNECTED;
        if (statusCallback) statusCallback(status);
        return false;
    }

    // Save original terminal settings
    if (tcgetattr(serialFd, &originalTios) < 0) {
        std::string errorMsg = "Failed to get terminal attributes: " + std::string(strerror(errno));
        setError(SERIAL_CONFIG_FAILED, errorMsg);
        OH_LOG_ERROR(LOG_APP, "%{public}s", errorMsg.c_str());
        close(serialFd);
        serialFd = -1;
        status = SessionStatus::DISCONNECTED;
        if (statusCallback) statusCallback(status);
        return false;
    }
    settingsSaved = true;

    // Configure serial port
    if (!configureSerialPort(baudRate, dataBits, stopBits, parity, flowControl)) {
        close(serialFd);
        serialFd = -1;
        status = SessionStatus::DISCONNECTED;
        if (statusCallback) statusCallback(status);
        return false;
    }

    // Start the receiving thread
    running = true;
    receiveThread = std::thread(&SerialSession::receiveLoop, this);

    // Update status to connected
    status = SessionStatus::CONNECTED;
    if (statusCallback) {
        statusCallback(status);
    }

    OH_LOG_INFO(LOG_APP, "Serial connection established to %{public}s at %{public}d baud",
                serialDevice.c_str(), baudRate);

    return true;
}

bool SerialSession::disconnect() {
    OH_LOG_INFO(LOG_APP, "Disconnecting from serial port");

    // Check if already disconnected
    if (status == SessionStatus::DISCONNECTED) {
        return true;
    }

    // Update status to disconnecting
    status = SessionStatus::DISCONNECTING;
    if (statusCallback) {
        statusCallback(status);
    }

    // Stop the receive thread
    running = false;
    if (receiveThread.joinable()) {
        receiveThread.join();
    }

    // Close the serial port
    if (serialFd >= 0) {
        // Restore original terminal settings if saved
        if (settingsSaved) {
            tcsetattr(serialFd, TCSANOW, &originalTios);
            settingsSaved = false;
        }

        close(serialFd);
        serialFd = -1;
    }

    // Update status to disconnected
    status = SessionStatus::DISCONNECTED;
    if (statusCallback) {
        statusCallback(status);
    }

    OH_LOG_INFO(LOG_APP, "Serial connection closed");
    return true;
}

bool SerialSession::sendData(const std::string& command) {
    OH_LOG_INFO(LOG_APP, "Sending data to serial port, length: %{public}zu", command.length());

    // Check if connected
    if (status != SessionStatus::CONNECTED || serialFd < 0) {
        setError(SERIAL_SEND_FAILED, "Not connected to serial port");
        return false;
    }

    // Protect serial port access
    std::lock_guard<std::mutex> lock(serialMutex);

    // Send data
    ssize_t bytesWritten = write(serialFd, command.c_str(), command.length());
    if (bytesWritten < 0) {
        std::string errorMsg = "Failed to write to serial port: " + std::string(strerror(errno));
        setError(SERIAL_SEND_FAILED, errorMsg);
        OH_LOG_ERROR(LOG_APP, "%{public}s", errorMsg.c_str());
        return false;
    } else if (bytesWritten < static_cast<ssize_t>(command.length())) {
        OH_LOG_WARN(LOG_APP, "Partial write to serial port: %{public}zd of %{public}zu bytes",
                   bytesWritten, command.length());
    }

    // Flush output
    if (tcdrain(serialFd) < 0) {
        OH_LOG_WARN(LOG_APP, "Failed to drain serial port: %{public}s", strerror(errno));
    }

    OH_LOG_INFO(LOG_APP, "Successfully sent %{public}zd bytes to serial port", bytesWritten);
    return true;
}

void SerialSession::receiveLoop() {
    OH_LOG_INFO(LOG_APP, "Starting serial receive loop");

    const int bufferSize = 4096;
    std::vector<char> recvbuf(bufferSize);
    ssize_t bytesReceived;

    while (running) {
        // Check if serial port is valid
        if (serialFd < 0) {
            OH_LOG_ERROR(LOG_APP, "Serial port is invalid in receive loop");
            break;
        }

        // Wait for data to be available
        fd_set readfds;
        struct timeval timeout;

        FD_ZERO(&readfds);
        FD_SET(serialFd, &readfds);

        timeout.tv_sec = 1;  // 1 second timeout
        timeout.tv_usec = 0;

        int selectResult = select(serialFd + 1, &readfds, NULL, NULL, &timeout);

        if (selectResult < 0) {
            // Error in select
            if (errno == EINTR) {
                // Interrupted by signal, just retry
                continue;
            }

            std::string errorMsg = "Select failed: " + std::string(strerror(errno));
            OH_LOG_ERROR(LOG_APP, "%{public}s", errorMsg.c_str());
            setError(SERIAL_RECEIVE_FAILED, errorMsg);
            break;
        } else if (selectResult == 0) {
            // Timeout, no data available
            continue;
        }

        // Data is available, read it
        bytesReceived = read(serialFd, recvbuf.data(), bufferSize);

        if (bytesReceived > 0) {
            OH_LOG_INFO(LOG_APP, "Received %{public}zd bytes from serial port", bytesReceived);

            // Create a string from the received data
            std::string receivedData(recvbuf.data(), bytesReceived);

            // Use callback or store in pending messages
            if (dataCallback) {
                try {
                    dataCallback(sessionId, receivedData, false);
                    OH_LOG_INFO(LOG_APP, "Data callback executed successfully");
                } catch (const std::exception& e) {
                    OH_LOG_ERROR(LOG_APP, "Exception in data callback: %{public}s", e.what());
                }
            } else {
                std::lock_guard<std::mutex> lock(pendingMessagesMutex);
                pendingMessages.push_back(receivedData);
                OH_LOG_INFO(LOG_APP, "No data callback available, stored in pending messages");
            }
        } else if (bytesReceived == 0) {
            // No data received, should not happen with a serial port
            OH_LOG_WARN(LOG_APP, "Zero bytes read from serial port");
            continue;
        } else { // bytesReceived < 0 (error)
            // Check if disconnect() was called
            if (!running) {
                OH_LOG_INFO(LOG_APP, "Receive loop stopping due to disconnect request");
                break;
            }

            // Handle specific errors
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Non-blocking socket would block, just continue
                continue;
            } else if (errno == EINTR) {
                // Interrupted by signal, just retry
                continue;
            } else {
                // Fatal error
                std::string errorMsg = "Receive failed: " + std::string(strerror(errno));
                OH_LOG_ERROR(LOG_APP, "%{public}s", errorMsg.c_str());
                setError(SERIAL_RECEIVE_FAILED, errorMsg);
                break;
            }
        }
    }

    OH_LOG_INFO(LOG_APP, "Serial receive loop finished");
}

bool SerialSession::configureSerialPort(int baudRate, int dataBits, int stopBits,
                                        SerialParity parity, SerialFlowControl flowControl) {
    struct termios tios;

    // Get current attributes
    if (tcgetattr(serialFd, &tios) < 0) {
        std::string errorMsg = "Failed to get terminal attributes: " + std::string(strerror(errno));
        setError(SERIAL_CONFIG_FAILED, errorMsg);
        OH_LOG_ERROR(LOG_APP, "%{public}s", errorMsg.c_str());
        return false;
    }

    // Clear all settings
    tios.c_cflag = 0;
    tios.c_iflag = 0;
    tios.c_oflag = 0;
    tios.c_lflag = 0;

    // Set basic flags for serial port
    tios.c_cflag |= CREAD | CLOCAL;  // Enable receiver, ignore modem control lines

    // Set baud rate
    speed_t baud;
    switch (baudRate) {
        case 50: baud = B50; break;
        case 75: baud = B75; break;
        case 110: baud = B110; break;
        case 134: baud = B134; break;
        case 150: baud = B150; break;
        case 200: baud = B200; break;
        case 300: baud = B300; break;
        case 600: baud = B600; break;
        case 1200: baud = B1200; break;
        case 1800: baud = B1800; break;
        case 2400: baud = B2400; break;
        case 4800: baud = B4800; break;
        case 9600: baud = B9600; break;
        case 19200: baud = B19200; break;
        case 38400: baud = B38400; break;
        case 57600: baud = B57600; break;
        case 115200: baud = B115200; break;
        case 230400: baud = B230400; break;
        default:
            setError(SERIAL_CONFIG_FAILED, "Unsupported baud rate: " + std::to_string(baudRate));
            OH_LOG_ERROR(LOG_APP, "Unsupported baud rate: %{public}d", baudRate);
            return false;
    }
    cfsetispeed(&tios, baud);
    cfsetospeed(&tios, baud);

    // Set data bits
    switch (dataBits) {
        case 5: tios.c_cflag |= CS5; break;
        case 6: tios.c_cflag |= CS6; break;
        case 7: tios.c_cflag |= CS7; break;
        case 8: tios.c_cflag |= CS8; break;
        default:
            setError(SERIAL_CONFIG_FAILED, "Unsupported data bits: " + std::to_string(dataBits));
            OH_LOG_ERROR(LOG_APP, "Unsupported data bits: %{public}d", dataBits);
            return false;
    }

    // Set parity
    switch (parity) {
        case PARITY_NONE:
            // No parity, do nothing
            break;
        case PARITY_ODD:
            tios.c_cflag |= PARENB | PARODD;
            break;
        case PARITY_EVEN:
            tios.c_cflag |= PARENB;
            break;
        case PARITY_MARK:
            // Mark parity not directly supported in POSIX, may need custom handling
            setError(SERIAL_CONFIG_FAILED, "Mark parity not supported");
            OH_LOG_ERROR(LOG_APP, "Mark parity not supported");
            return false;
        case PARITY_SPACE:
            // Space parity not directly supported in POSIX, may need custom handling
            setError(SERIAL_CONFIG_FAILED, "Space parity not supported");
            OH_LOG_ERROR(LOG_APP, "Space parity not supported");
            return false;
        default:
            setError(SERIAL_CONFIG_FAILED, "Invalid parity setting");
            OH_LOG_ERROR(LOG_APP, "Invalid parity setting");
            return false;
    }

    // Set stop bits
    if (stopBits == 2) {
        tios.c_cflag |= CSTOPB;
    }
    // 1 stop bit is default (no flag needed)

    // Set flow control
    switch (flowControl) {
        case FLOW_NONE:
            // No flow control, do nothing
            break;
        case FLOW_XONXOFF:
            tios.c_iflag |= IXON | IXOFF;
            break;
        case FLOW_RTSCTS:
            tios.c_cflag |= CRTSCTS;
            break;
        case FLOW_DSRDTR:
            // DSR/DTR flow control not directly supported in POSIX, may need custom handling
            setError(SERIAL_CONFIG_FAILED, "DSR/DTR flow control not supported");
            OH_LOG_ERROR(LOG_APP, "DSR/DTR flow control not supported");
            return false;
        default:
            setError(SERIAL_CONFIG_FAILED, "Invalid flow control setting");
            OH_LOG_ERROR(LOG_APP, "Invalid flow control setting");
            return false;
    }

    // Set non-canonical mode (raw mode)
    // No special processing of input/output characters
    tios.c_lflag &= ~(ICANON | ECHO | ECHOE | ISIG);
    tios.c_oflag &= ~OPOST;

    // Set timeouts
    tios.c_cc[VMIN] = 0;   // Return immediately with what is available
    tios.c_cc[VTIME] = 1;  // 0.1 second timeout

    // Apply settings
    if (tcsetattr(serialFd, TCSANOW, &tios) < 0) {
        std::string errorMsg = "Failed to set terminal attributes: " + std::string(strerror(errno));
        setError(SERIAL_CONFIG_FAILED, errorMsg);
        OH_LOG_ERROR(LOG_APP, "%{public}s", errorMsg.c_str());
        return false;
    }

    // Flush any existing data
    if (tcflush(serialFd, TCIOFLUSH) < 0) {
        OH_LOG_WARN(LOG_APP, "Failed to flush serial port: %{public}s", strerror(errno));
    }

    OH_LOG_INFO(LOG_APP, "Serial port configured successfully");
    return true;
}

void SerialSession::setError(SerialError code, const std::string& message) {
    lastError.code = code;
    lastError.message = message;
    OH_LOG_ERROR(LOG_APP, "Serial error: %{public}s", message.c_str());
}

// --- 新增：setLogging 的实现 ---
bool SerialSession::setLogging(int fd, int logType, int existOperation, bool includeHeader, bool omitKnownPassword, bool omitSessionData) {
    OH_LOG_INFO(LOG_APP, "[SerialSession] setLogging called with fd=%{public}d, logType=%{public}d, existOperation=%{public}d, includeHeader=%{public}d, omitKnownPassword=%{public}d, omitSessionData=%{public}d", 
        fd, logType, existOperation, includeHeader, omitKnownPassword, omitSessionData);
    
    // 串口会话通常不直接写入日志文件，日志由上层NAPI处理或通过dataCallback转发
    // 但我们可以记录这些配置参数以供将来使用
    if (logType == 0 || fd < 0) {
        OH_LOG_INFO(LOG_APP, "[SerialSession] setLogging: 参数指示禁用日志");
        // 可以在这里清理任何串口特定的日志状态
    } else {
        OH_LOG_INFO(LOG_APP, "[SerialSession] setLogging: 参数指示启用日志");
        // 可以在这里设置串口特定的日志配置
        // 注意：串口会话的数据通常通过dataCallback回调处理，而不是直接写入文件
    }
    
    // 返回 true 表示函数调用本身成功
    return true;
}

// --- 新增：resizeTerminal 的实现 ---
bool SerialSession::resizeTerminal(int width, int height) {
    // 串口通信不涉及终端大小调整
    OH_LOG_WARN(LOG_APP, "[SerialSession] resizeTerminal called but ignored (width=%{public}d, height=%{public}d)",
                width, height);
    // 返回 true 表示函数调用本身成功，即使它没有实际操作
    // 或者返回 false 表示此功能不支持
    return false; // 返回 false 可能更符合语义
}
