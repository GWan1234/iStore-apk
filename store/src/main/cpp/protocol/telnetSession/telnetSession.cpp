#include "telnetSession.h"
#include <iostream>
#include <vector>
#include <stdexcept>
#include <hilog/log.h>
#include <fcntl.h> // 确保 fcntl 已包含
#include <errno.h> // 确保 errno 已包含
#include <cstring> // 确保 strerror 已包含

// Use cJSON for JSON parsing
extern "C" {
#include "../jsonAnalyse/cJSON.h"
}

#undef LOG_DOMAIN 
#undef LOG_TAG 
#define LOG_DOMAIN 0x3200  // 全局domain宏，标识业务领域
#define LOG_TAG "MY_TAG"   // 全局tag宏，标识模块日志tag

TelnetSession::TelnetSession() {
    status = SessionStatus::DISCONNECTED;

    // Initialize supported options
    localOptions[TELOPT_BINARY] = true;
    localOptions[TELOPT_SGA] = true;
    localOptions[TELOPT_ECHO] = false; // We don't want to echo
    localOptions[TELOPT_TTYPE] = true;
    localOptions[TELOPT_NAWS] = true;

    // Initialize command buffer
    commandBuffer.reserve(256);

    // --- 新增：初始化日志状态 ---
    logManagerInitialized.store(false);
    // ---------------------------
}

TelnetSession::~TelnetSession() {
    // Stop keep-alive thread if running
    stopKeepAlive();

    // Ensure disconnect is called
    disconnect(); // disconnect 会清理 initialBuffer

    // Wait for receive thread to finish
    if (receiveThread.joinable()) {
        receiveThread.join();
    }
}

// Helper method to set error information
void TelnetSession::setError(TelnetError code, const std::string& message) {
    lastError = {code, message};
    OH_LOG_ERROR(LOG_APP, "Telnet error: %{public}d - %{public}s", code, message.c_str());
}

// Helper method to set socket to non-blocking mode
bool TelnetSession::setSocketNonBlocking(int socket) {
    int flags = fcntl(socket, F_GETFL, 0);
    if (flags == -1) {
        setError(TELNET_SOCKET_ERROR, "Failed to get socket flags: " + std::string(strerror(errno)));
        return false;
    }

    if (fcntl(socket, F_SETFL, flags | O_NONBLOCK) == -1) {
        setError(TELNET_SOCKET_ERROR, "Failed to set socket non-blocking: " + std::string(strerror(errno)));
        return false;
    }

    return true;
}

// Helper method to wait for socket to be readable
bool TelnetSession::waitForSocketReadable(int socket, int timeoutSec) {
    fd_set readfds;
    FD_ZERO(&readfds);
    FD_SET(socket, &readfds);

    struct timeval tv;
    tv.tv_sec = timeoutSec;
    tv.tv_usec = 0;

    int result = select(socket + 1, &readfds, NULL, NULL, &tv);
    if (result < 0) {
        setError(TELNET_SOCKET_ERROR, "Select failed: " + std::string(strerror(errno)));
        return false;
    } else if (result == 0) {
        // Timeout
        return false;
    }

    return FD_ISSET(socket, &readfds);
}

// Helper method to wait for socket to be writable
bool TelnetSession::waitForSocketWritable(int socket, int timeoutSec) {
    fd_set writefds;
    FD_ZERO(&writefds);
    FD_SET(socket, &writefds);

    struct timeval tv;
    tv.tv_sec = timeoutSec;
    tv.tv_usec = 0;

    int result = select(socket + 1, NULL, &writefds, NULL, &tv);
    if (result < 0) {
        setError(TELNET_SOCKET_ERROR, "Select failed: " + std::string(strerror(errno)));
        return false;
    } else if (result == 0) {
        // Timeout
        return false;
    }

    return FD_ISSET(socket, &writefds);
}

// Helper method to escape IAC characters in data
std::string TelnetSession::escapeIAC(const std::string& data) const {
    std::string result;
    result.reserve(data.size() * 2); // Reserve space for worst case

    for (char c : data) {
        if ((unsigned char)c == TELNET_IAC) {
            result.push_back((char)TELNET_IAC); // Double IAC to escape it
        }
        result.push_back(c);
    }

    return result;
}

// Open Telnet connection
bool TelnetSession::openConnect(const std::string& napiInput) {
    OH_LOG_INFO(LOG_APP, "Opening Telnet connection with input: %{public}s", napiInput.c_str());

    // Check if already connected or connecting
    if (status != SessionStatus::DISCONNECTED) {
        setError(TELNET_INVALID_PARAMS, "Session is already connected or connecting");
        return false;
    }

    // Update status to connecting
    status = SessionStatus::CONNECTING;
    if (statusCallback) {
        statusCallback(status);
    }

    // Default connection parameters
    std::string host;
    int port = 23; // Default Telnet port
    int connectTimeout = 10; // Default timeout in seconds

    // Parse JSON input
    cJSON *json = cJSON_Parse(napiInput.c_str());
    if (json == NULL) {
        const char *error_ptr = cJSON_GetErrorPtr();
        std::string errorMsg = "Failed to parse JSON input";
        if (error_ptr != NULL) {
            errorMsg += ": ";
            errorMsg += error_ptr;
        }
        setError(TELNET_INVALID_PARAMS, errorMsg);
        status = SessionStatus::DISCONNECTED;
        if (statusCallback) statusCallback(status);
        return false;
    }

    // Extract Telnet object from JSON
    cJSON *telnetObj = cJSON_GetObjectItemCaseSensitive(json, "Telnet");
    if (!cJSON_IsObject(telnetObj)) {
        setError(TELNET_INVALID_PARAMS, "Missing 'Telnet' object in JSON input");
        cJSON_Delete(json);
        status = SessionStatus::DISCONNECTED;
        if (statusCallback) statusCallback(status);
        return false;
    }

    // Extract host
    cJSON *hostJson = cJSON_GetObjectItemCaseSensitive(telnetObj, "hostName");
    if (cJSON_IsString(hostJson) && (hostJson->valuestring != NULL)) {
        host = hostJson->valuestring;
    } else {
        setError(TELNET_INVALID_PARAMS, "Host is missing or not a string in connection parameters");
        cJSON_Delete(json);
        status = SessionStatus::DISCONNECTED;
        if (statusCallback) statusCallback(status);
        return false;
    }

    // Extract port
    cJSON *portJson = cJSON_GetObjectItemCaseSensitive(telnetObj, "port");
    if (cJSON_IsString(portJson) && portJson->valuestring != NULL) {
        try {
            port = std::stoi(portJson->valuestring);
        } catch (const std::exception& e) {
            OH_LOG_WARN(LOG_APP, "Invalid port number, using default: %{public}s", e.what());
            port = 23; // Use default on error
        }
    }

    // Extract Connection object for additional parameters
    cJSON *connObj = cJSON_GetObjectItemCaseSensitive(json, "Connection");
    if (cJSON_IsObject(connObj)) {
        // Extract keepalive interval
        cJSON *keepaliveJson = cJSON_GetObjectItemCaseSensitive(connObj, "keepalive");
        if (cJSON_IsNumber(keepaliveJson)) {
            keepAliveInterval = keepaliveJson->valueint;
            OH_LOG_INFO(LOG_APP, "Using keepalive interval: %{public}d seconds", keepAliveInterval);
        }
    }

    // Extract timeout
    cJSON *timeoutJson = cJSON_GetObjectItemCaseSensitive(telnetObj, "timeout");
    if (cJSON_IsNumber(timeoutJson)) {
        connectTimeout = timeoutJson->valueint;
    }

    // Extract terminal type if present
    cJSON *terminalTypeJson = cJSON_GetObjectItemCaseSensitive(telnetObj, "terminalType");
    if (cJSON_IsString(terminalTypeJson) && terminalTypeJson->valuestring != NULL) {
        terminalType = terminalTypeJson->valuestring;
    }

    // Extract newline mode if present
    cJSON *newlineModeJson = cJSON_GetObjectItemCaseSensitive(telnetObj, "newlineMode");
    if (cJSON_IsString(newlineModeJson) && newlineModeJson->valuestring != NULL) {
        std::string nlMode = newlineModeJson->valuestring;
        if (nlMode == "CR") {
            newlineMode = NEWLINE_CR;
        } else if (nlMode == "LF") {
            newlineMode = NEWLINE_LF;
        } else {
            newlineMode = NEWLINE_CRLF;
        }
    }

    // Done with JSON parsing
    cJSON_Delete(json);

    OH_LOG_INFO(LOG_APP, "Connecting to Telnet server %{public}s:%{public}d", host.c_str(), port);

    // Set up address info structures
    addrinfo *result = nullptr, *ptr = nullptr, hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC; // Allow IPv4 or IPv6
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    // Convert port to string for getaddrinfo
    std::string portStr = std::to_string(port);
    int addrResult = getaddrinfo(host.c_str(), portStr.c_str(), &hints, &result);
    if (addrResult != 0) {
        std::string errorMsg = "getaddrinfo failed: " + std::string(gai_strerror(addrResult));
        setError(TELNET_CONNECT_FAILED, errorMsg);
        status = SessionStatus::DISCONNECTED;
        if (statusCallback) statusCallback(status);
        return false;
    }

    // Attempt to connect to an address until one succeeds
    bool connected = false;
    for (ptr = result; ptr != NULL; ptr = ptr->ai_next) {
        // Create socket
        connectSocket = socket(ptr->ai_family, ptr->ai_socktype, ptr->ai_protocol);
        if (connectSocket == INVALID_SOCKET) {
            OH_LOG_WARN(LOG_APP, "Socket creation failed: %{public}s", strerror(errno));
            continue;
        }

        // Set socket to non-blocking mode for timeout support
        if (!setSocketNonBlocking(connectSocket)) {
            close(connectSocket);
            connectSocket = INVALID_SOCKET;
            continue;
        }

        // Attempt non-blocking connect
        int connectResult = ::connect(connectSocket, ptr->ai_addr, (int)ptr->ai_addrlen);
        if (connectResult == 0) {
            // Immediate success (rare)
            connected = true;
            break;
        } else if (errno != EINPROGRESS) {
            // Connect error other than in-progress
            OH_LOG_WARN(LOG_APP, "Connection failed: %{public}s", strerror(errno));
            close(connectSocket);
            connectSocket = INVALID_SOCKET;
            continue;
        }

        // Wait for connection to complete or timeout
        if (waitForSocketWritable(connectSocket, connectTimeout)) {
            // Check if connection was successful
            int error = 0;
            socklen_t len = sizeof(error);
            if (getsockopt(connectSocket, SOL_SOCKET, SO_ERROR, &error, &len) < 0 || error != 0) {
                OH_LOG_WARN(LOG_APP, "Connection failed after select: %{public}s",
                           error ? strerror(error) : strerror(errno));
                close(connectSocket);
                connectSocket = INVALID_SOCKET;
                continue;
            }

            // Connection successful
            connected = true;
            break;
        } else {
            // Connection timeout
            OH_LOG_WARN(LOG_APP, "Connection timed out after %{public}d seconds", connectTimeout);
            close(connectSocket);
            connectSocket = INVALID_SOCKET;
            continue;
        }
    }

    // Free address info structure
    freeaddrinfo(result);

    // Check if connection was successful
    if (!connected || connectSocket == INVALID_SOCKET) {
        setError(TELNET_CONNECT_FAILED, "Failed to connect to server");
        status = SessionStatus::DISCONNECTED;
        if (statusCallback) statusCallback(status);
        return false;
    }

    // Set socket back to blocking mode for normal operation
    int flags = fcntl(connectSocket, F_GETFL, 0);
    fcntl(connectSocket, F_SETFL, flags & ~O_NONBLOCK);

    // --- 在启动线程之前 ---
    // 重置日志状态，以防重连
    logManagerInitialized.store(false);
    {
        std::lock_guard<std::mutex> lock(bufferMutex);
        initialBuffer.clear();
    }
    // --------------------

    // Start the keep-alive thread if interval > 0
    if (keepAliveInterval > 0) {
        startKeepAlive();
    }

    // Start the receiving thread
    running = true;
    receiveThread = std::thread(&TelnetSession::receiveLoop, this);

    // Update status to connected
    status = SessionStatus::CONNECTED;
    if (statusCallback) {
        statusCallback(status);
    }

    OH_LOG_INFO(LOG_APP, "Telnet connection established to %{public}s:%{public}d", host.c_str(), port);

    return true;
}

bool TelnetSession::disconnect() {
    OH_LOG_INFO(LOG_APP, "Disconnecting Telnet session");

    // --- 新增：清理日志缓冲区 ---
    {
        std::lock_guard<std::mutex> lock(bufferMutex);
        initialBuffer.clear();
        // 不需要重置 logManagerInitialized，因为它控制日志写入，
        // 而断开连接后不应再写入。下次连接时会重置。
    }
    // --------------------------

    // Check if already disconnected or disconnecting
    if (status == SessionStatus::DISCONNECTED || status == SessionStatus::DISCONNECTING) {
        OH_LOG_INFO(LOG_APP, "Session already disconnected or disconnecting");
        return true;
    }

    // Update status to disconnecting
    status = SessionStatus::DISCONNECTING;
    if (statusCallback) {
        try {
            statusCallback(status);
        } catch (const std::exception& e) {
            OH_LOG_ERROR(LOG_APP, "Exception in status callback: %{public}s", e.what());
        }
    }

    // Stop keep-alive thread
    stopKeepAlive();

    // Signal the receiving thread to stop
    running = false;

    // Close the socket
    if (connectSocket != INVALID_SOCKET) {
        std::lock_guard<std::mutex> lock(socketMutex); // Protect socket access

        // Shutdown socket to unblock any pending operations
        if (shutdown(connectSocket, SHUT_RDWR) != 0) {
            OH_LOG_WARN(LOG_APP, "Socket shutdown failed: %{public}s", strerror(errno));
        }

        // Close socket
        if (close(connectSocket) != 0) {
            OH_LOG_WARN(LOG_APP, "Socket close failed: %{public}s", strerror(errno));
        }

        connectSocket = INVALID_SOCKET;
        OH_LOG_INFO(LOG_APP, "Telnet socket closed");
    }

    // Wait for the receiving thread to finish with timeout
    if (receiveThread.joinable()) {
        OH_LOG_INFO(LOG_APP, "Waiting for receive thread to finish");
        receiveThread.join();
        OH_LOG_INFO(LOG_APP, "Telnet receive thread joined");
    }

    // Clear command buffer and state
    {
        std::lock_guard<std::mutex> lock(commandMutex);
        commandBuffer.clear();
        inIAC = false;
        inSB = false;
    }

    // Update status to disconnected
    status = SessionStatus::DISCONNECTED;
    if (statusCallback) {
        try {
            statusCallback(status);
        } catch (const std::exception& e) {
            OH_LOG_ERROR(LOG_APP, "Exception in status callback: %{public}s", e.what());
        }
    }

    // 禁用日志管理器并刷新尾行（如有）
    try {
        logManager.disable();
        logManagerInitialized.store(false);
    } catch (...) {
        OH_LOG_WARN(LOG_APP, "TelnetSession::disconnect: exception while disabling LogManager");
    }

    // Send disconnection message to frontend (similar to SSH)
    pendingCallData("Telnet连接已断开", true);

    OH_LOG_INFO(LOG_APP, "Telnet session disconnected");
    return true;
}

bool TelnetSession::sendData(const std::string& command) {
    OH_LOG_INFO(LOG_APP, "Sending data to Telnet server, length: %{public}zu", command.length());

    // Check if connected
    if (status != SessionStatus::CONNECTED || connectSocket == INVALID_SOCKET) {
        setError(TELNET_SEND_FAILED, "Not connected to server");
        return false;
    }

    // Protect socket access
    std::lock_guard<std::mutex> lock(socketMutex);

    // --- 修改开始: 不再自动添加换行符, 也不转义 IAC ---
    // Telnet 要求发送原始数据中的 IAC (255) 时，必须将其转义为 IAC IAC.
    // 但是，命令通常不包含 IAC。如果需要发送包含 IAC 的数据，则调用者应负责转义。
    // 这里假设调用者（JS）发送的是用户输入或简单命令，不需要转义。
    // 同时，移除自动添加的行尾符。
    const std::string& dataToSend = command; // 直接使用传入的命令
    /*
    // Escape IAC characters in command
    std::string escapedCommand = escapeIAC(command);

    // Add appropriate line ending based on configured newline mode
    std::string dataToSend;
    switch (newlineMode) {
        case NEWLINE_CR:
            dataToSend = escapedCommand + "\r";
            break;
        case NEWLINE_LF:
            dataToSend = escapedCommand + "\n";
            break;
        case NEWLINE_CRLF:
        default:
            dataToSend = escapedCommand + "\r\n";
            break;
    }
    */
    // --- 修改结束 ---

    // Send data with handling for partial sends
    size_t totalSent = 0;
    size_t dataLength = dataToSend.length();
    int maxAttempts = 5;
    int attempts = 0;

    while (totalSent < dataLength && attempts < maxAttempts) {
        int bytesSent = send(connectSocket,
                             dataToSend.c_str() + totalSent,
                             dataLength - totalSent,
                             0);

        if (bytesSent > 0) {
            totalSent += bytesSent;
            attempts = 0; // Reset attempts counter on successful send
        } else if (bytesSent == 0) {
            // Connection closed
            setError(TELNET_SEND_FAILED, "Connection closed by peer");
            disconnect();
            return false;
        } else { // bytesSent < 0 (error)
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Socket would block, wait and retry
                attempts++;
                OH_LOG_WARN(LOG_APP, "Socket would block, attempt %{public}d/%{public}d",
                           attempts, maxAttempts);

                // Wait for socket to be writable
                if (!waitForSocketWritable(connectSocket, 1)) {
                    setError(TELNET_SEND_FAILED, "Timeout waiting for socket to be writable");
                    return false;
                }
            } else {
                // Other socket error
                std::string errorMsg = "Send failed: " + std::string(strerror(errno));
                setError(TELNET_SEND_FAILED, errorMsg);
                disconnect();
                return false;
            }
        }
    }

    // Check if all data was sent
    if (totalSent < dataLength) {
        setError(TELNET_SEND_FAILED, "Failed to send all data after multiple attempts");
        return false;
    }

    OH_LOG_INFO(LOG_APP, "Successfully sent %{public}zu bytes to Telnet server", totalSent);
    return true;
}

void TelnetSession::receiveLoop() {
    OH_LOG_INFO(LOG_APP, "Starting Telnet receive loop");

    const int bufferSize = 4096;
    std::vector<char> recvbuf(bufferSize);
    int bytesReceived;

    while (running) {
        // Check if socket is valid
        if (connectSocket == INVALID_SOCKET) {
            OH_LOG_ERROR(LOG_APP, "Socket is invalid in receive loop");
            break;
        }

        // Receive data from socket
        bytesReceived = recv(connectSocket, recvbuf.data(), bufferSize, 0);

        if (bytesReceived > 0) {
            OH_LOG_INFO(LOG_APP, "Received %{public}d bytes from Telnet server", bytesReceived);

            // Process Telnet commands and extract actual data
            std::vector<char> processedData;
            processTelnetCommand(
                reinterpret_cast<const unsigned char*>(recvbuf.data()),
                bytesReceived,
                processedData
            );

            // If there's processed data
            if (!processedData.empty()) {
                // --- 修改：日志处理 ---
                const char* dataPtr = processedData.data();
                size_t dataLen = processedData.size();
                if (!logManagerInitialized.load()) {
                    std::lock_guard<std::mutex> bufferLock(bufferMutex);
                     if (!logManagerInitialized.load()) {
                         if (initialBuffer.length() + dataLen < MAX_INITIAL_BUFFER_SIZE) {
                            initialBuffer.append(dataPtr, dataLen);
                             OH_LOG_INFO(LOG_APP, "[Telnet] Appended data to initial buffer. Buffer size: %zu", initialBuffer.length());
                         } else {
                             OH_LOG_WARN(LOG_APP, "[Telnet] Initial buffer full, dropping data.");
                         }
                     } else {
                         logManager.writeLog(dataPtr, dataLen);
                     }
                } else {
                    logManager.writeLog(dataPtr, dataLen);
                }
                // ---------------------

                std::string receivedDataStr(processedData.begin(), processedData.end());
                OH_LOG_INFO(LOG_APP, "Received data from server, length: %{public}zu, data: %{public}s",
                            receivedDataStr.length(), receivedDataStr.substr(0, 100).c_str());

                if (dataCallback) {
                    try {
                        // 这里发送的是普通数据，status 依然是 false (表示未结束)
                        // 注意：Telnet协议本身没有明确的"消息结束"标志，所以这里用 false
                        dataCallback(sessionId, receivedDataStr, false); 
                        OH_LOG_INFO(LOG_APP, "Data callback executed successfully");
                    } catch (const std::exception& e) {
                        OH_LOG_ERROR(LOG_APP, "Exception in data callback: %{public}s", e.what());
                    }
                } else {
                    std::lock_guard<std::mutex> lock(pendingMessagesMutex);
                    pendingMessages.push_back(receivedDataStr);
                    OH_LOG_INFO(LOG_APP, "No data callback available, stored in pending messages");
                }
            }
        } else if (bytesReceived == 0) {
            // Connection closed gracefully by peer
            OH_LOG_INFO(LOG_APP, "Telnet connection closed by peer");
            running = false; // Stop the loop

            // Update status if not already disconnecting
            if (status != SessionStatus::DISCONNECTING) {
                status = SessionStatus::DISCONNECTED;
                // Notify via callback (保留，可能用于其他目的)
                if (statusCallback) {
                    try {
                        statusCallback(status);
                    } catch (const std::exception& e) {
                        OH_LOG_ERROR(LOG_APP, "Exception in status callback: %{public}s", e.what());
                    }
                }
                // 添加断开提示到终端，与SSH保持一致
                pendingCallData("Connection closed or error occurred in receive thread", true);
            }
        } else { // bytesReceived < 0 (error)
            // Check if disconnect() was called
            if (!running) {
                OH_LOG_INFO(LOG_APP, "Receive loop stopping due to disconnect request");
                break;
            }

            // Handle specific socket errors
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            } else if (errno == EINTR) {
                continue;
            } else {
                // Fatal socket error
                std::string errorMsg = "Receive failed: " + std::string(strerror(errno));
                OH_LOG_ERROR(LOG_APP, "%{public}s", errorMsg.c_str());
                setError(TELNET_RECEIVE_FAILED, errorMsg);
                running = false;

                // Update status if not already disconnecting
                if (status != SessionStatus::DISCONNECTING) {
                    status = SessionStatus::DISCONNECTED;
                    // Notify via callback (保留)
                    if (statusCallback) {
                        try {
                            statusCallback(status);
                        } catch (const std::exception& e) {
                            OH_LOG_ERROR(LOG_APP, "Exception in status callback: %{public}s", e.what());
                        }
                    }
                    // Send error disconnection message to frontend
                    pendingCallData("Connection closed or error occurred in receive thread", true);
                }
            }
        }
    }

    OH_LOG_INFO(LOG_APP, "Telnet receive loop finished");
}

// Send data to callback with status (similar to SSH implementation)
void TelnetSession::pendingCallData(std::string data, bool status) {
    // Directly call the callback function to avoid queue buffering and reduce latency
    if (dataCallback) {
        try {
            dataCallback(sessionId, data, status);
            return;
        } catch (const std::exception& e) {
            OH_LOG_ERROR(LOG_APP, "Exception in data callback: %s", e.what());
        } catch (...) {
            OH_LOG_ERROR(LOG_APP, "Unknown exception in data callback");
        }
    }
    
    // If no callback or callback failed, log the message
    OH_LOG_INFO(LOG_APP, "Telnet status message: %{public}s (status: %{public}d)", data.c_str(), status);
}


// Process Telnet commands and extract actual data
void TelnetSession::processTelnetCommand(const unsigned char* buffer, int len, std::vector<char>& processedData) {
    std::lock_guard<std::mutex> lock(commandMutex);

    // Reserve space in processed data buffer
    processedData.reserve(len);

    for (int i = 0; i < len; i++) {
        // Check if we're in the middle of processing an IAC sequence
        if (inIAC) {
            // We've already seen IAC, now check the command
            if (inSB) {
                // We're in a subnegotiation
                if (buffer[i] == TELNET_IAC) {
                    // Could be IAC SE (end of subnegotiation) or escaped IAC
                    if (i + 1 < len && buffer[i + 1] == TELNET_SE) {
                        // End of subnegotiation
                        inSB = false;
                        inIAC = false;
                        i++; // Skip the SE byte

                        // Process the subnegotiation data in commandBuffer
                        if (!commandBuffer.empty()) {
                            handleSubnegotiation(commandBuffer.data(), commandBuffer.size());
                            commandBuffer.clear();
                        }
                    } else {
                        // Escaped IAC within subnegotiation
                        commandBuffer.push_back(TELNET_IAC);
                    }
                } else {
                    // Regular subnegotiation data
                    commandBuffer.push_back(buffer[i]);
                }
            } else if (buffer[i] == TELNET_SB) {
                // Start of subnegotiation
                inSB = true;
                commandBuffer.clear();
            } else if (buffer[i] == TELNET_WILL || buffer[i] == TELNET_WONT ||
                       buffer[i] == TELNET_DO || buffer[i] == TELNET_DONT) {
                // Option negotiation command
                if (i + 1 < len) {
                    // We have the option byte in this buffer
                    unsigned char option = buffer[i + 1];
                    handleOptionNegotiation(buffer[i], option);
                    i++; // Skip the option byte
                    inIAC = false;
                } else {
                    // Option byte will be in the next buffer
                    commandBuffer.push_back(buffer[i]);
                    // Keep inIAC true to continue processing in next call
                }
            } else if (buffer[i] == TELNET_IAC) {
                // Double IAC means literal IAC character
                processedData.push_back((char)TELNET_IAC);
                inIAC = false;
            } else {
                // Simple command (like NOP, BRK, etc.)
                handleSimpleCommand(buffer[i]);
                inIAC = false;
            }
        } else if (buffer[i] == TELNET_IAC) {
            // Start of IAC sequence
            inIAC = true;

            // If we have a partial command from previous buffer, clear it
            if (!commandBuffer.empty() && !inSB) {
                commandBuffer.clear();
            }
        } else {
            // Regular data byte
            processedData.push_back((char)buffer[i]);
        }
    }
}

// Handle Telnet option negotiation
void TelnetSession::handleOptionNegotiation(unsigned char cmd, unsigned char option) {
    OH_LOG_INFO(LOG_APP, "Telnet option negotiation: %{public}u %{public}u", cmd, option);

    unsigned char response[3] = {TELNET_IAC, 0, option};

    switch (cmd) {
        case TELNET_DO:
            // Server wants us to enable an option
            if (supportedOption(option)) {
                response[1] = TELNET_WILL;
                localOptions[option] = true;
                OH_LOG_INFO(LOG_APP, "Accepting DO %{public}u", option);
            } else {
                response[1] = TELNET_WONT;
                OH_LOG_INFO(LOG_APP, "Rejecting DO %{public}u", option);
            }
            break;

        case TELNET_DONT:
            // Server wants us to disable an option
            response[1] = TELNET_WONT;
            localOptions[option] = false;
            OH_LOG_INFO(LOG_APP, "Accepting DONT %{public}u", option);
            break;

        case TELNET_WILL:
            // Server wants to enable an option
            if (acceptableOption(option)) {
                response[1] = TELNET_DO;
                remoteOptions[option] = true;
                OH_LOG_INFO(LOG_APP, "Accepting WILL %{public}u", option);
            } else {
                response[1] = TELNET_DONT;
                OH_LOG_INFO(LOG_APP, "Rejecting WILL %{public}u", option);
            }
            break;

        case TELNET_WONT:
            // Server wants to disable an option
            response[1] = TELNET_DONT;
            remoteOptions[option] = false;
            OH_LOG_INFO(LOG_APP, "Accepting WONT %{public}u", option);
            break;

        default:
            // Invalid command
            OH_LOG_ERROR(LOG_APP, "Invalid option negotiation command: %{public}u", cmd);
            return;
    }

    // Send response
    std::lock_guard<std::mutex> lock(socketMutex);
    if (connectSocket != INVALID_SOCKET) {
        ssize_t bytes_sent = send(connectSocket, (const char*)response, 3, 0);
        if (bytes_sent != 3) {
             OH_LOG_ERROR(LOG_APP, "Failed to send option negotiation response for option %{public}u, cmd %{public}u. Sent %{public}zd bytes, expected 3. Error: %{public}s", option, cmd, bytes_sent, strerror(errno));
             // Optionally handle the error, e.g., disconnect or retry
             return; // Don't proceed if send failed
        } else {
             OH_LOG_INFO(LOG_APP, "Sent option negotiation response: IAC %{public}u %{public}u", response[1], option);
        }
    } else {
         OH_LOG_WARN(LOG_APP, "Cannot send option negotiation response, socket is invalid.");
         return; // Don't proceed if socket is invalid
    }

    // If we just agreed to send terminal type (replied WILL to DO TTYPE), send it now
    if (cmd == TELNET_DO && option == TELOPT_TTYPE && response[1] == TELNET_WILL) {
        OH_LOG_INFO(LOG_APP, "Negotiation requires sending terminal type now.");
        // Unlock mutex before calling another function that might lock it
        socketMutex.unlock();
        sendTerminalType();
        // Re-lock might be needed if more operations follow, but not in this case.
        return; // Exit after handling TTYPE specific action
    }

    // If we just agreed to send window size, send it now
    // Note: This should be handled in resizeTerminal typically, but keep for completeness
    if (cmd == TELNET_DO && option == TELOPT_NAWS && response[1] == TELNET_WILL) {
         OH_LOG_INFO(LOG_APP, "Negotiation requires sending window size now (if available).");
         // Unlock mutex before calling another function that might lock it
         socketMutex.unlock();
         sendWindowSize();
         // Re-lock might be needed if more operations follow, but not in this case.
         return; // Exit after handling NAWS specific action
    }
}

// Handle simple Telnet commands (like NOP, BRK, etc.)
void TelnetSession::handleSimpleCommand(unsigned char cmd) {
    switch (cmd) {
        case TELNET_NOP:
            OH_LOG_INFO(LOG_APP, "Received NOP command");
            break;

        case TELNET_DM:
            OH_LOG_INFO(LOG_APP, "Received Data Mark command");
            break;

        case TELNET_BRK:
            OH_LOG_INFO(LOG_APP, "Received Break command");
            break;

        case TELNET_IP:
            OH_LOG_INFO(LOG_APP, "Received Interrupt Process command");
            break;

        case TELNET_AO:
            OH_LOG_INFO(LOG_APP, "Received Abort Output command");
            break;

        case TELNET_AYT:
            OH_LOG_INFO(LOG_APP, "Received Are You There command");
            // Could send back some response
            break;

        case TELNET_EC:
            OH_LOG_INFO(LOG_APP, "Received Erase Character command");
            break;

        case TELNET_EL:
            OH_LOG_INFO(LOG_APP, "Received Erase Line command");
            break;

        case TELNET_GA:
            OH_LOG_INFO(LOG_APP, "Received Go Ahead command");
            break;

        default:
            OH_LOG_WARN(LOG_APP, "Received unknown Telnet command: %{public}u", cmd);
            break;
    }
}

// Handle Telnet subnegotiation
void TelnetSession::handleSubnegotiation(const unsigned char* data, size_t length) {
    if (length < 1) {
        OH_LOG_ERROR(LOG_APP, "Empty subnegotiation data");
        return;
    }

    unsigned char option = data[0];
    OH_LOG_INFO(LOG_APP, "Telnet subnegotiation for option: %{public}u", option);

    switch (option) {
        case TELOPT_TTYPE:
            if (length >= 2 && data[1] == 1) { // SEND command
                sendTerminalType();
            }
            break;

        case TELOPT_NAWS:
            // Server shouldn't send NAWS subnegotiation, but handle it anyway
            OH_LOG_WARN(LOG_APP, "Unexpected NAWS subnegotiation from server");
            break;

        default:
            OH_LOG_WARN(LOG_APP, "Unhandled subnegotiation for option: %{public}u", option);
            break;
    }
}

// Send terminal type to server
void TelnetSession::sendTerminalType() {
    // Format: IAC SB TTYPE IS "xterm" IAC SE
    std::vector<unsigned char> response;
    response.push_back(TELNET_IAC);
    response.push_back(TELNET_SB);
    response.push_back(TELOPT_TTYPE);
    response.push_back(0); // IS

    // Add terminal type string
    for (char c : terminalType) {
        response.push_back(c);
    }

    response.push_back(TELNET_IAC);
    response.push_back(TELNET_SE);

    // Send response
    std::lock_guard<std::mutex> lock(socketMutex);
    if (connectSocket != INVALID_SOCKET) {
        send(connectSocket, (const char*)response.data(), response.size(), 0);
        OH_LOG_INFO(LOG_APP, "Sent terminal type: %{public}s", terminalType.c_str());
    }
}

// Send window size to server
void TelnetSession::sendWindowSize() {
    // Format: IAC SB NAWS width-high width-low height-high height-low IAC SE
    unsigned char response[9];
    response[0] = TELNET_IAC;
    response[1] = TELNET_SB;
    response[2] = TELOPT_NAWS;
    response[3] = (windowSize.width >> 8) & 0xFF; // width high byte
    response[4] = windowSize.width & 0xFF;        // width low byte
    response[5] = (windowSize.height >> 8) & 0xFF; // height high byte
    response[6] = windowSize.height & 0xFF;        // height low byte
    response[7] = TELNET_IAC;
    response[8] = TELNET_SE;

    // Send response
    std::lock_guard<std::mutex> lock(socketMutex);
    if (connectSocket != INVALID_SOCKET) {
        send(connectSocket, (const char*)response, 9, 0);
        OH_LOG_INFO(LOG_APP, "Sent window size: %{public}dx%{public}d",
                   windowSize.width, windowSize.height);
    }
}

// Check if we support a specific option
bool TelnetSession::supportedOption(unsigned char option) const {
    auto it = localOptions.find(option);
    if (it != localOptions.end()) {
        return it->second;
    }
    return false;
}

// Check if we accept a specific option from the server
bool TelnetSession::acceptableOption(unsigned char option) const {
    // We accept most standard options
    switch (option) {
        case TELOPT_BINARY:
        case TELOPT_ECHO:
        case TELOPT_SGA:
        case TELOPT_STATUS:
        case TELOPT_TIMING_MARK:
            return true;

        default:
            return false;
    }
}

// Start keep-alive thread
void TelnetSession::startKeepAlive() {
    // Stop any existing keep-alive thread
    stopKeepAlive();

    // Start new keep-alive thread if interval > 0
    if (keepAliveInterval > 0) {
        OH_LOG_INFO(LOG_APP, "Starting keep-alive thread with interval %{public}d seconds", keepAliveInterval);
        keepAliveRunning = true;
        keepAliveThread = std::thread(&TelnetSession::keepAliveLoop, this);
    }
}

// Stop keep-alive thread
void TelnetSession::stopKeepAlive() {
    // Signal thread to stop
    if (keepAliveRunning) {
        OH_LOG_INFO(LOG_APP, "Stopping keep-alive thread");
        keepAliveRunning = false;

        // Wait for thread to finish
        if (keepAliveThread.joinable()) {
            keepAliveThread.join();
        }
    }
}

// Keep-alive thread function
void TelnetSession::keepAliveLoop() {
    OH_LOG_INFO(LOG_APP, "Keep-alive thread started");

    while (keepAliveRunning) {
        // Sleep for the specified interval
        for (int i = 0; i < keepAliveInterval && keepAliveRunning; i++) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }

        // Check if we should still be running
        if (!keepAliveRunning) {
            break;
        }

        // Send NOP command as keep-alive
        std::lock_guard<std::mutex> lock(socketMutex);
        if (connectSocket != INVALID_SOCKET && status == SessionStatus::CONNECTED) {
            unsigned char nop[2] = {TELNET_IAC, TELNET_NOP};
            send(connectSocket, (const char*)nop, 2, 0);
            OH_LOG_INFO(LOG_APP, "Sent keep-alive NOP command");
        }
    }

    OH_LOG_INFO(LOG_APP, "Keep-alive thread stopped");
}

// Resize terminal
bool TelnetSession::resizeTerminal(int width, int height) {
    OH_LOG_INFO(LOG_APP, "Resizing terminal to %{public}dx%{public}d", width, height);

    // Check if connected
    if (status != SessionStatus::CONNECTED) {
        setError(TELNET_INVALID_PARAMS, "Not connected to server");
        return false;
    }

    // Update window size
    windowSize.width = width;
    windowSize.height = height;

    // Check if NAWS option is enabled
    auto it = localOptions.find(TELOPT_NAWS);
    if (it != localOptions.end() && it->second) {
        // Send window size to server
        sendWindowSize();
        return true;
    } else {
        OH_LOG_WARN(LOG_APP, "NAWS option not enabled, window size not sent");
        return false;
    }
}

// --- 新增：实现 setLogging 方法 ---
bool TelnetSession::setLogging(int fd, int logType, int existOperation, bool includeHeader, bool omitKnownPassword, bool omitSessionData) {
    OH_LOG_INFO(LOG_APP, "[Telnet] setLogging called with fd=%{public}d, logType=%{public}d, existOperation=%{public}d, includeHeader=%{public}d, omitKnownPassword=%{public}d, omitSessionData=%{public}d", 
        fd, logType, existOperation, includeHeader, omitKnownPassword, omitSessionData);
    bool success = false;
    bool loggingEnabled = false;

    try {
        // 根据参数直接初始化或禁用 LogManager
        if (logType == 0 || fd < 0) {
            OH_LOG_INFO(LOG_APP, "[Telnet] setLogging: 参数指示禁用日志，调用 logManager.disable()");
            logManager.disable();
            loggingEnabled = false; // 标记日志为禁用
        } else {
            OH_LOG_INFO(LOG_APP, "[Telnet] setLogging: 参数指示启用日志，调用 logManager.init()");
            logManager.init(fd, logType, existOperation, includeHeader, omitKnownPassword, omitSessionData);
            loggingEnabled = true; // 标记日志为启用
        }
        OH_LOG_INFO(LOG_APP, "[Telnet] LogManager 配置完成 (通过 setLogging)。");
        success = true;

        // --- 处理初始缓冲区 ---
        std::string bufferedData;
        {
            std::lock_guard<std::mutex> bufferLock(bufferMutex);
            // 只有在日志实际启用时才写入缓冲区
            if (loggingEnabled && !initialBuffer.empty()) {
                OH_LOG_INFO(LOG_APP, "[Telnet] setLogging: LogManager 初始化完成，开始写入 %zu 字节的初始缓冲区数据...", initialBuffer.length());
                bufferedData = std::move(initialBuffer); // 移动数据以减少拷贝
                initialBuffer.clear(); // 确保清空
            } else if (!initialBuffer.empty()) {
                 OH_LOG_INFO(LOG_APP, "[Telnet] setLogging: LogManager 已禁用或缓冲区为空，丢弃初始缓冲区数据。");
                 initialBuffer.clear(); // 如果日志被禁用，也清空缓冲区
            }
            // --- 设置初始化标志 ---
            logManagerInitialized.store(true);
            OH_LOG_INFO(LOG_APP, "[Telnet] setLogging: logManagerInitialized 标志设置为 true.");
        } // 释放 bufferMutex

        // 在锁外部写入数据，避免长时间持有锁
        if (loggingEnabled && !bufferedData.empty()) {
            try {
                logManager.writeLog(bufferedData.c_str(), bufferedData.length());
                OH_LOG_INFO(LOG_APP, "[Telnet] setLogging: 初始缓冲区数据写入完成。");
            } catch(const std::exception& writeEx) {
                 OH_LOG_ERROR(LOG_APP, "[Telnet] setLogging: 写入初始缓冲区数据时发生异常: %{public}s", writeEx.what());
                 // success 已经为 true，这里只记录错误
            } catch(...) {
                 OH_LOG_ERROR(LOG_APP, "[Telnet] setLogging: 写入初始缓冲区数据时发生未知异常。");
            }
        }
        // --------------------

        return success; // 返回 setLogging 操作本身的成功状态

    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[Telnet] 配置 LogManager 失败: %{public}s", e.what());
        // 尝试在错误时禁用
        try {
            logManager.disable();
        } catch(...) { /*忽略禁用时的错误*/ }
         // 即使配置失败，也要标记初始化完成（虽然是失败的初始化），避免 receiveData 永远缓冲
         logManagerInitialized.store(true);
         OH_LOG_WARN(LOG_APP, "[Telnet] setLogging: 因异常设置 logManagerInitialized 标志为 true，但日志可能未启用。");
        return false; // 返回 setLogging 失败
    }
}
// ----------------------------


