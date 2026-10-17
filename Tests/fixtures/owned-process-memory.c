// Read-only counters for a benchmark's own same-user child and exact executable.
#include <libproc.h>
#include <sys/proc_info.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <errno.h>
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    char *end=NULL;errno=0;long parsed=strtol(argv[1],&end,10);
    if(errno||!end||*end||parsed<=0||parsed>INT_MAX)return 2;
    pid_t pid=(pid_t)parsed;char path[PROC_PIDPATHINFO_MAXSIZE]={0};
    struct proc_bsdinfo before={0},after={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&before,sizeof(before))!=sizeof(before)||
       before.pbi_pid!=(unsigned)pid||before.pbi_uid!=getuid()||before.pbi_ruid!=getuid()||
       proc_pidpath(pid,path,sizeof(path))<=0||strcmp(path,argv[2]))return 2;
    struct rusage_info_v4 value={0};
    if(proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t *)&value))return 3;
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&after,sizeof(after))!=sizeof(after)||
       before.pbi_pid!=after.pbi_pid||before.pbi_start_tvsec!=after.pbi_start_tvsec||
       before.pbi_start_tvusec!=after.pbi_start_tvusec||before.pbi_uid!=after.pbi_uid||
       before.pbi_ruid!=after.pbi_ruid||proc_pidpath(pid,path,sizeof(path))<=0||strcmp(path,argv[2]))return 4;
    printf("{\"footprint\":%llu,\"resident\":%llu,\"start\":%llu}\n",
           (unsigned long long)value.ri_phys_footprint,(unsigned long long)value.ri_resident_size,
           (unsigned long long)value.ri_proc_start_abstime);
    return 0;
}
