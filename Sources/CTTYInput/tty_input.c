#include "CTTYInput.h"
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <math.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

double ap_tty_uptime(void){
    mach_timebase_info_data_t base;mach_timebase_info(&base);
    // Includes system sleep; an old mobile packet must expire while the Mac
    // sleeps instead of being delivered minutes later when it wakes.
    return (double)mach_continuous_time()*(double)base.numer/(double)base.denom/1e9;
}
int ap_tty_identity(pid_t pid,APTTYIdentity *result){
    if(pid<=0||!result)return EINVAL;
    struct proc_bsdinfo info;
    int count=proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info));
    if(count!=(int)sizeof(info))return count<0?errno:ESRCH;
    *result=(APTTYIdentity){(int32_t)info.pbi_pid,(int32_t)info.pbi_pgid,(int32_t)info.e_tpgid,
        info.pbi_ruid,info.pbi_uid,info.e_tdev,info.pbi_start_tvsec,info.pbi_start_tvusec};
    return 0;
}
static int validate(const APTTYIdentity *expected,uid_t caller){
    APTTYIdentity current;int error=ap_tty_identity(expected->pid,&current);if(error)return error;
    if(current.uid!=caller||current.euid!=caller||caller==0)return EACCES;
    if(current.pid!=expected->pid||current.process_group!=expected->process_group||
       current.foreground_group!=expected->process_group||expected->foreground_group!=expected->process_group||
       current.device!=expected->device||current.start_seconds!=expected->start_seconds||
       current.start_microseconds!=expected->start_microseconds||
       current.uid!=expected->uid||current.euid!=expected->euid)return ESTALE;
    return 0;
}
static int valid_tty(const char *tty){
    if(!tty||strncmp(tty,"/dev/ttys",9))return 0;
    size_t length=strlen(tty);if(length<10||length>14)return 0;
    for(size_t i=9;i<length;i++)if(tty[i]<'0'||tty[i]>'9')return 0;
    return 1;
}
int ap_tty_write(const APTTYIdentity *identity,uid_t caller,const char *tty,
                 const unsigned char *bytes,size_t length,double deadline,APTTYWriteResult *result){
    if(!result)return EINVAL;result->written=0;
    double now=ap_tty_uptime();
    if(!identity||!bytes||!length||length>8000||!valid_tty(tty)||
       !isfinite(deadline)||deadline>now+2.1)return EINVAL;
    if(deadline<=now)return ETIMEDOUT;
    int error=validate(identity,caller);if(error)return error;
    int fd=open(tty,O_RDONLY|O_NOCTTY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0)return errno;
    struct stat device;
    if(fstat(fd,&device))error=errno;
    else if(!S_ISCHR(device.st_mode)||device.st_uid!=caller)error=EACCES;
    else if((uint32_t)device.st_rdev!=identity->device)error=ESTALE;
    while(!error&&result->written<length){
        if(ap_tty_uptime()>=deadline){error=ETIMEDOUT;break;}
        error=validate(identity,caller);if(error)break;
        // TIOCGPGRP/tcgetpgrp requires the caller's own controlling TTY even
        // for root. The source's libproc e_tpgid above is the foreground check.
        struct termios mode;
        if(tcgetattr(fd,&mode)){error=errno;break;}
        // FIONREAD cannot count an unfinished canonical line. Never report
        // success for an unbounded queue or change the original terminal mode.
        if(mode.c_lflag&ICANON){error=EOPNOTSUPP;break;}
        int pending=0;
        if(ioctl(fd,FIONREAD,&pending)){error=errno;break;}
        if(pending>512){usleep(2000);continue;}
        if(ioctl(fd,TIOCSTI,&bytes[result->written])){error=errno;break;}
        result->written++;
    }
    close(fd);return error;
}
