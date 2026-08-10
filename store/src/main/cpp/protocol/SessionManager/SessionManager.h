#ifndef LIBSSH2_SESSIONMANAGER_H
#define LIBSSH2_SESSIONMANAGER_H

#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <functional>
#include <mutex>
#include <iostream>

#include "protocol/SessionFactory/SessionFactory.h"

class Session;
class SshSession;

class SessionManager {
public:
    static SessionManager& getInstance() {
        
        static SessionManager instance;
        return instance;
    }

    std::shared_ptr<Session> createSession(PROTOCOL type);
    
    bool destroySession(int sessionId);
    
    bool destroySession(std::shared_ptr<Session> session);
    
    std::shared_ptr<Session> getSession(int sessionId);
    
    int getSessionId(std::shared_ptr<Session> session);
    
    void addPendingDataCallback(std::function<void(int, const std::string&, bool)> callback);
    
    void addPendingDirectoryChangeCallback(std::function<void(int, const std::string&)> callback);
    
    void applyDirectoryChangeCallbackToExistingSessions(std::function<void(int, const std::string&)> callback);

    void applyPendingCallbacks(std::shared_ptr<Session> session);

    void clearPendingCallbacks();

    void applyDataCallbackToExistingSessions(std::function<void(int, const std::string&, bool)> callback);

private:
    SessionManager() = default;
    
    std::map<int, std::shared_ptr<Session>> sessions;
    
    std::vector<std::function<void(int, const std::string&, bool)>> pendingDataCallbacks;
    std::vector<std::function<void(int, const std::string&)>> pendingDirChangeCallbacks;
    
    std::mutex mutex; // 统一锁，保护sessions和回调
    
    int nextSessionId = 0;
};

#endif //LIBSSH2_SESSIONMANAGER_H
