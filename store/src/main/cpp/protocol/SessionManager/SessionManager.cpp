#include "SessionManager.h"
#include "protocol/Session.h"
#include "protocol/ssh/SshSession.h"
#include <utility>

std::shared_ptr<Session> SessionManager::createSession(PROTOCOL type) {
    std::lock_guard<std::mutex> lock(mutex);
    auto session = SessionFactory::createSession(type);
    int id = nextSessionId++;
    session->setSessionId(id);
    sessions[id] = session;
    OH_LOG_INFO(LOG_APP, "[SessionManager] Created session ID %{public}d. About to apply pending callbacks.", id);
    applyPendingCallbacks(session);
    OH_LOG_INFO(LOG_APP, "[SessionManager] Finished applying pending callbacks for session ID %{public}d.", id);
    return session;
}

bool SessionManager::destroySession(int sessionId) {
    std::lock_guard<std::mutex> lock(mutex);
    auto it = sessions.find(sessionId);
    if (it != sessions.end()) {
        sessions.erase(it);
        return true;
    }
    else {
         return false;
    }
}

bool SessionManager::destroySession(std::shared_ptr<Session> session) {
    if (!session) return false;
    std::lock_guard<std::mutex> lock(mutex);
    int sessionId = -1;
    for (auto it = sessions.begin(); it != sessions.end(); ++it) {
        if (it->second == session) {
            sessionId = it->first;
            sessions.erase(it);
            return true;
        }
    }
    return false;
}

std::shared_ptr<Session> SessionManager::getSession(int sessionId) {
    std::lock_guard<std::mutex> lock(mutex);
    auto it = sessions.find(sessionId);
    if (it != sessions.end()) {
        return it->second;
    }
    else {
        // throw std::invalid_argument("Session ID not found: " + std::to_string(sessionId));
        // Return nullptr if session ID is not found
        OH_LOG_WARN(LOG_APP, "[SessionManager] Session ID %{public}d not found.", sessionId);
        return nullptr;
    }
}

int SessionManager::getSessionId(std::shared_ptr<Session> session) {
    if (!session) return -1;
    std::lock_guard<std::mutex> lock(mutex);
    int id = session->getSessionId();
    auto it = sessions.find(id);
    if (it != sessions.end() && it->second == session) {
        return id;
    }
    
    for (const auto& entry : sessions) {
        if (entry.second == session) {
            return entry.first;
        }
    }
    return -1;
}

void SessionManager::addPendingDataCallback(std::function<void(int, const std::string&, bool)> callback) {
    std::lock_guard<std::mutex> lock(mutex);
    pendingDataCallbacks.push_back(std::move(callback));
}

void SessionManager::addPendingDirectoryChangeCallback(std::function<void(int, const std::string&)> callback) {
    std::lock_guard<std::mutex> lock(mutex);
    pendingDirChangeCallbacks.push_back(std::move(callback));
}

void SessionManager::applyDirectoryChangeCallbackToExistingSessions(std::function<void(int, const std::string&)> callback) {
    std::lock_guard<std::mutex> lock(mutex);
    for (auto const& [id, session_ptr] : sessions) { 
        SshSession* sshSession = dynamic_cast<SshSession*>(session_ptr.get());
        if (sshSession) { 
            int currentSessionId = id;
            auto adaptedCallback = [originalCallback = callback, currentSessionId](const std::string& dir) {
                originalCallback(currentSessionId, dir);
            };
            sshSession->setDirectoryChangeCallback(adaptedCallback);
        } 
    }
}

void SessionManager::applyPendingCallbacks(std::shared_ptr<Session> session) {
    if (!session) return;
    OH_LOG_INFO(LOG_APP, "[SessionManager] Applying pending callbacks for session ID %{public}d.", session->getSessionId());
    for (const auto& callback : pendingDataCallbacks) {
        OH_LOG_INFO(LOG_APP, "[SessionManager] Applying pending data callback to session ID %{public}d.", session->getSessionId());
        session->setDataCallbacks(callback);
        OH_LOG_INFO(LOG_APP, "[SessionManager] Finished applying pending data callback to session ID %{public}d.", session->getSessionId());
    }

    SshSession* sshSession = dynamic_cast<SshSession*>(session.get());
    if (sshSession) {
        int currentSessionId = session->getSessionId();
        for (const auto& originalCallback : pendingDirChangeCallbacks) {
            auto adaptedCallback = [originalCallback, currentSessionId](const std::string& dir) {
                originalCallback(currentSessionId, dir);
            };
            sshSession->setDirectoryChangeCallback(adaptedCallback);
        }
    }
}

void SessionManager::clearPendingCallbacks() {
    std::lock_guard<std::mutex> lock(mutex);
    pendingDataCallbacks.clear();
    pendingDirChangeCallbacks.clear();
}

void SessionManager::applyDataCallbackToExistingSessions(std::function<void(int, const std::string&, bool)> callback) {
    std::lock_guard<std::mutex> lock(mutex);
    OH_LOG_INFO(LOG_APP, "Applying data callback to %zu existing sessions.", sessions.size());
    for (auto const& [id, session_ptr] : sessions) {
        if (session_ptr) { // 确保指针有效
            try {
                // Session 基类应该有 setDataCallbacks 方法
                session_ptr->setDataCallbacks(callback);
                OH_LOG_INFO(LOG_APP, "Applied data callback to session ID=%d", id);
            } catch (const std::exception& e) {
                OH_LOG_ERROR(LOG_APP, "Error applying data callback to session ID=%d: %s", id, e.what());
            } catch (...) {
                OH_LOG_ERROR(LOG_APP, "Unknown error applying data callback to session ID=%d", id);
            }
        }
    }
}
