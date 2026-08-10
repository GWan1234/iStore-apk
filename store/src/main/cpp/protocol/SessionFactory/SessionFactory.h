#ifndef LIBSSH2_SESSIONFACTORY_H
#define LIBSSH2_SESSIONFACTORY_H

#include <string>
#include <memory>

#include "protocol/ssh/SshSession.h"
#include "protocol/telnetSession/telnetSession.h"
#include "protocol/serialSession/serialSession.h"

class Session;

class SessionFactory {
public:
    static std::shared_ptr<Session> createSession(PROTOCOL type);
};

#endif //LIBSSH2_SESSIONFACTORY_H
