#ifndef AUTOAPPROVE_NATIVE_PEER_H
#define AUTOAPPROVE_NATIVE_PEER_H
#include <stdint.h>
typedef struct {
    uint32_t pid, effective_uid, effective_gid, audit_pid_version;
    /* The complete kernel token binds code validation to this process lifetime. */
    uint32_t audit_token[8];
} aa_native_peer_identity;
/* Returns errno on failure. Values come from the connected socket, never JSON. */
int aa_native_peer_from_socket(int fd, aa_native_peer_identity *identity);
/* Sends one tagged byte and one descriptor. Returns 0 or errno; never retries. */
int aa_native_send_descriptor(int socket_fd, int descriptor);
#endif
