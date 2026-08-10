#ifndef LIBSSH2_TELNETSESSION_H
#define LIBSSH2_TELNETSESSION_H

#include "protocol/Session.h"
#include <thread>
#include <atomic>
#include <vector>
#include <mutex>
#include <map>
#include <queue>
#include <string>
#include <fcntl.h> // For fcntl() and non-blocking socket

// Include POSIX socket headers
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h> // For close()
#include <netdb.h> // For getaddrinfo()
#include <sys/select.h> // For select()

#include "protocol/ssh/LogManager.h"
#include <memory>

// Define socket constants if not implicitly defined (though usually are in headers)
#ifndef INVALID_SOCKET
#define INVALID_SOCKET -1
#endif
#ifndef SOCKET_ERROR
#define SOCKET_ERROR -1
#endif

// Telnet protocol constants
#define TELNET_IAC   255 // Interpret As Command
#define TELNET_DONT  254
#define TELNET_DO    253
#define TELNET_WONT  252
#define TELNET_WILL  251
#define TELNET_SB    250 // Subnegotiation Begin
#define TELNET_SE    240 // Subnegotiation End
#define TELNET_NOP   241 // No Operation
#define TELNET_DM    242 // Data Mark
#define TELNET_BRK   243 // Break
#define TELNET_IP    244 // Interrupt Process
#define TELNET_AO    245 // Abort Output
#define TELNET_AYT   246 // Are You There
#define TELNET_EC    247 // Erase Character
#define TELNET_EL    248 // Erase Line
#define TELNET_GA    249 // Go Ahead

// Telnet options
#define TELOPT_BINARY            0  // Binary Transmission
#define TELOPT_ECHO              1  // Echo
#define TELOPT_SGA               3  // Suppress Go Ahead
#define TELOPT_STATUS            5  // Status
#define TELOPT_TIMING_MARK       6  // Timing Mark
#define TELOPT_TTYPE             24 // Terminal Type
#define TELOPT_NAWS              31 // Negotiate About Window Size
#define TELOPT_SPEED             32 // Terminal Speed
#define TELOPT_LFLOW             33 // Remote Flow Control
#define TELOPT_LINEMODE          34 // Linemode
#define TELOPT_NEW_ENVIRON       39 // New Environment

// Telnet error codes
enum TelnetError {
    TELNET_OK = 0,
    TELNET_CONNECT_FAILED,
    TELNET_SOCKET_ERROR,
    TELNET_INVALID_PARAMS,
    TELNET_TIMEOUT,
    TELNET_PROTOCOL_ERROR,
    TELNET_SEND_FAILED,
    TELNET_RECEIVE_FAILED
};

// Error information structure
struct ErrorInfo {
    TelnetError code;
    std::string message;
};

// Telnet session state
class TelnetSession : public Session {
public:
    TelnetSession();
    ~TelnetSession() override;

    bool openConnect(const std::string& napiInput) override;
    bool disconnect() override;
    bool sendData(const std::string& command) override;

    // New method to resize terminal
    bool resizeTerminal(int width, int height) override;

    // Get last error information
    ErrorInfo getLastError() const { return lastError; }

    // Send data to callback with status (similar to SSH implementation)
    void pendingCallData(std::string data, bool status);

    // 新增: 设置日志
    bool setLogging(int fd, int logType, int existOperation, bool includeHeader = false, bool omitKnownPassword = false, bool omitSessionData = false) override;

private:
    // Telnet protocol handling
    void receiveLoop(); // Background thread function for receiving data
    void processTelnetCommand(const unsigned char* buffer, int len, std::vector<char>& processedData);
    void handleOptionNegotiation(unsigned char cmd, unsigned char option);
    void handleSimpleCommand(unsigned char cmd);
    void handleSubnegotiation(const unsigned char* data, size_t length);
    void sendTerminalType();
    void sendWindowSize();
    bool supportedOption(unsigned char option) const;
    bool acceptableOption(unsigned char option) const;

    // Keep-alive mechanism
    void keepAliveLoop();
    void startKeepAlive();
    void stopKeepAlive();

    // Helper methods
    void setError(TelnetError code, const std::string& message);
    std::string escapeIAC(const std::string& data) const;

    // Socket and connection
    int connectSocket = INVALID_SOCKET; // Use standard int for socket descriptor
    bool setSocketNonBlocking(int socket);
    bool waitForSocketReadable(int socket, int timeoutSec);
    bool waitForSocketWritable(int socket, int timeoutSec);

    // Threading
    std::thread receiveThread;
    std::atomic<bool> running{false};
    std::mutex socketMutex; // Mutex to protect socket access
    std::mutex commandMutex; // Mutex for telnet command processing

    // Keep-alive
    std::atomic<bool> keepAliveRunning{false};
    std::thread keepAliveThread;
    int keepAliveInterval = 60; // seconds

    // Telnet state
    enum NewlineMode {
        NEWLINE_CR,
        NEWLINE_LF,
        NEWLINE_CRLF
    } newlineMode = NEWLINE_CRLF;

    std::string terminalType = "xterm";
    struct WindowSize {
        int width = 80;
        int height = 24;
    } windowSize;

    // Option negotiation state
    std::map<unsigned char, bool> localOptions;  // Options we support
    std::map<unsigned char, bool> remoteOptions; // Options remote end supports

    // Command buffer for handling split IAC sequences
    std::vector<unsigned char> commandBuffer;
    bool inIAC = false;
    bool inSB = false;

    // Error handling
    ErrorInfo lastError = {TELNET_OK, ""};

    // --- 新增：日志相关成员（按会话隔离，避免并发会话覆盖同一 fd/状态） ---
    LogManager logManager;
    std::string initialBuffer;
    std::mutex bufferMutex;
    std::atomic<bool> logManagerInitialized{false};
    static const size_t MAX_INITIAL_BUFFER_SIZE = 16 * 1024; // 与 SshSession 保持一致
    // -------------------------
};

#endif // LIBSSH2_TELNETSESSION_H
