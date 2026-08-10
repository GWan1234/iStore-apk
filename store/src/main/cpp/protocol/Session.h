#ifndef LIBSSH2_SESSION_H
#define LIBSSH2_SESSION_H

#include <mutex>
#include <string>
#include <functional>
#include <vector>

enum class SessionStatus {
    CONNECTING,
    CONNECTED,
    DISCONNECTING,
    DISCONNECTED
};

class Session {
protected:
    
    int timeout;
    
    SessionStatus status;
    
    std::function<void(int, std::string, bool)> dataCallback;
    
    std::function<void(SessionStatus)> statusCallback;
    
    std::vector<std::string> pendingMessages;

    std::mutex pendingMessagesMutex;
    
    int sessionId = -1;
    
public:


    virtual ~Session() = default;

    virtual bool openConnect(const std::string& napiInput) = 0;
    
    virtual bool disconnect() = 0;
    
    virtual bool sendData(const std::string& command) = 0;

    virtual bool setLogging(int fd, int logType, int existOperation, bool includeHeader = false, bool omitKnownPassword = false, bool omitSessionData = false) = 0;

    virtual bool resizeTerminal(int width, int height) = 0;

    void setSessionId(int id) {
        sessionId = id;
    }
    
    int getSessionId() const {
        return sessionId;
    }

    void setDataCallbacks(std::function<void(int, std::string, bool)> dataCb) {
        
        std::lock_guard<std::mutex> lock(pendingMessagesMutex);
        if (dataCb == nullptr) {
            return;
        }
        dataCallback = dataCb;

        for (const auto& msg : pendingMessages) {
            dataCallback(sessionId, msg, false);
        }
        pendingMessages.clear();
    }

    void setSessionCallbacks(std::function<void(SessionStatus)> statusCb) {
        
        if (statusCb == nullptr) {
            return;
        }
        
        statusCallback = statusCb;
    }
    
    SessionStatus getStatus() const {
        return status;
    }
};

#endif //LIBSSH2_SESSION_H
