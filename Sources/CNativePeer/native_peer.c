#include "CNativePeer.h"
#include <bsm/libbsm.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>
#include <string.h>

int aa_native_peer_from_socket(int fd, aa_native_peer_identity *identity) {
    if (!identity) return EINVAL;
    memset(identity, 0, sizeof(*identity));
    int kind = 0;
    socklen_t length = sizeof(kind);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &length)) return errno;
    if (length != sizeof(kind) || kind != SOCK_STREAM) return EPROTOTYPE;
    audit_token_t token;
    length = sizeof(token);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length)) return errno;
    if (length != sizeof(token)) return EPROTO;
    pid_t pid = audit_token_to_pid(token);
    uint32_t version = (uint32_t)audit_token_to_pidversion(token);
    if (pid <= 0 || !version) return EPROTO;
    identity->pid = (uint32_t)pid;
    identity->effective_uid = audit_token_to_euid(token);
    identity->effective_gid = audit_token_to_egid(token);
    identity->audit_pid_version = version;
    return 0;
}
