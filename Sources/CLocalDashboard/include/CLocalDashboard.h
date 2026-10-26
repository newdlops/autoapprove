#ifndef AUTOAPPROVE_LOCAL_DASHBOARD_H
#define AUTOAPPROVE_LOCAL_DASHBOARD_H
/* Fixed /private/etc/hosts only; 0 reads, 1 opens append/read-write after OS authorization. */
int aa_open_dashboard_hosts(int writable);
/* Each tool gets a new process group. Only this owned group may be stopped. */
int aa_spawn_owned_tool(const char *path, char *const argv[], char *const envp[], const char *cwd, int output_fd, int error_fd, int *pid);
int aa_poll_owned_tool(int pid, int *exit_code);
void aa_stop_owned_tool(int pid);
#endif
