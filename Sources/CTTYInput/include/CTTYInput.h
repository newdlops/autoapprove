#ifndef AUTOAPPROVE_CTTYINPUT_H
#define AUTOAPPROVE_CTTYINPUT_H
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
typedef struct {
    int32_t pid,process_group,foreground_group;
    uint32_t uid,euid,device;
    uint64_t start_seconds,start_microseconds;
} APTTYIdentity;
double ap_tty_uptime(void);
int ap_tty_identity(pid_t pid,APTTYIdentity *result);
#endif
