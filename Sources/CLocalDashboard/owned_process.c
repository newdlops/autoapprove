#include "CLocalDashboard.h"
#include <spawn.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <time.h>

int aa_spawn_owned_tool(const char *path, char *const argv[], char *const envp[], const char *cwd, int output_fd, int error_fd, int *pid) {
    posix_spawn_file_actions_t files;
    posix_spawnattr_t attributes;
    int result=posix_spawn_file_actions_init(&files);
    if(result)return result;
    result=posix_spawnattr_init(&attributes);
    if(result){posix_spawn_file_actions_destroy(&files);return result;}
    sigset_t empty,defaults;sigemptyset(&empty);sigemptyset(&defaults);
    sigaddset(&defaults,SIGTERM);sigaddset(&defaults,SIGINT);sigaddset(&defaults,SIGPIPE);
    if(!(result=posix_spawn_file_actions_addopen(&files,STDIN_FILENO,"/dev/null",O_RDONLY,0)) &&
       !(result=posix_spawn_file_actions_adddup2(&files,output_fd,STDOUT_FILENO)) &&
       !(result=posix_spawn_file_actions_adddup2(&files,error_fd,STDERR_FILENO)) &&
       !(result=posix_spawn_file_actions_addchdir_np(&files,cwd)) &&
       !(result=posix_spawnattr_setpgroup(&attributes,0)) &&
       !(result=posix_spawnattr_setsigmask(&attributes,&empty)) &&
       !(result=posix_spawnattr_setsigdefault(&attributes,&defaults)) &&
       !(result=posix_spawnattr_setflags(&attributes,POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF))) {
        pid_t child=0;result=posix_spawn(&child,path,&files,&attributes,argv,envp);
        if(!result)*pid=child;
    }
    posix_spawnattr_destroy(&attributes);posix_spawn_file_actions_destroy(&files);return result;
}
static void reap_owned(int pid,int *exit_code) {
    int status=0;pid_t result;
    do{result=waitpid(pid,&status,0);}while(result<0&&errno==EINTR);
    if(exit_code)*exit_code=result<0 ? -1 : WIFEXITED(status) ? WEXITSTATUS(status) : 128+WTERMSIG(status);
}
int aa_poll_owned_tool(int pid,int *exit_code) {
    if(pid<=0)return -1;
    siginfo_t info;memset(&info,0,sizeof info);
    if(waitid(P_PID,(id_t)pid,&info,WEXITED|WNOHANG|WNOWAIT))return errno==EINTR ? 0 : -1;
    if(!info.si_pid)return 0;
    // Keep the exited leader's PID reserved until its remaining children stop.
    kill(-pid,SIGKILL);reap_owned(pid,exit_code);return 1;
}
void aa_stop_owned_tool(int pid) {
    if(pid<=0)return;
    kill(-pid,SIGTERM);
    struct timespec pause={0,250000000};while(nanosleep(&pause,&pause)&&errno==EINTR){}
    kill(-pid,SIGKILL);reap_owned(pid,0);
}
