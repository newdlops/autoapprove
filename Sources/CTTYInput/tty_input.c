#include "CTTYInput.h"
#include <errno.h>
#include <libproc.h>
#include <mach/mach_time.h>

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
