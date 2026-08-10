#include "SessionFactory.h"
#include "protocol/ssh/SshSession.h"
#include "protocol/telnetSession/telnetSession.h"
#include "protocol/serialSession/serialSession.h"
#include "jsonAnalyse/jsonAnalyse.h"

std::shared_ptr<Session> SessionFactory::createSession(PROTOCOL type) {

    switch (type) {
    case SSH:
        return std::static_pointer_cast<Session>(std::make_shared<SshSession>());
    case SERIAL:
        return std::static_pointer_cast<Session>(std::make_shared<SerialSession>());
    case TELNET:
        return std::static_pointer_cast<Session>(std::make_shared<TelnetSession>());
    case RAW:
        std::cerr << "Raw protocol not implemented yet." << std::endl;
        break;
    case ERROR:
        std::cerr << "Error protocol type encountered." << std::endl;
        return nullptr;
    default:
        std::cerr << "Unknown protocol type encountered." << std::endl;
        return nullptr;
    }
    return nullptr;
}
