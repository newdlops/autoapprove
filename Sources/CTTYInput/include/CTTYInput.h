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
typedef struct { size_t written; } APTTYWriteResult;
double ap_tty_uptime(void);
int ap_tty_identity(pid_t pid,APTTYIdentity *result);
int ap_tty_write(const APTTYIdentity *identity,uid_t caller,const char *tty,
                 const unsigned char *bytes,size_t length,double deadline,APTTYWriteResult *result);
#endif
