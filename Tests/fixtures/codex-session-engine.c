// SQLite-only idle CLI fixture. All files and PTYs belong to the test.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <signal.h>
#include <termios.h>
#include <sqlite3.h>
static int busy_goal=0,paused_goal=0;
static void pause_goal(void){char path[4096];snprintf(path,sizeof(path),"%s/goals_1.sqlite",getenv("CODEX_HOME"));sqlite3 *db=NULL;if(sqlite3_open(path,&db)==SQLITE_OK)sqlite3_exec(db,"UPDATE thread_goals SET status='paused',updated_at_ms=120000 WHERE status='active'",NULL,NULL,NULL);if(db)sqlite3_close(db);busy_goal=0;paused_goal=1;}
static void ready(void);
static char *input_line(char *line,size_t size){size_t n=0;for(;;){int c=getchar();if(c==EOF)return NULL;if(c==27&&busy_goal){if(getenv("IGNORE_GOAL_PAUSE"))continue;pause_goal();fputs("\033[2J\033[H",stdout);ready();continue;}if(n+1<size)line[n++]=(char)c;if(c=='\n'||c=='\r'){line[n-1]='\n';line[n]=0;return line;}}}
static pid_t tool_child=-1,extra_tool=-1;
static void linger(int sig){alarm(3);}
static pid_t spawn_tool(const char *tool){pid_t child=fork();if(child==0){setpgid(0,0);execl(tool,tool,"--fixture-tool-host",NULL);_exit(23);}return child;}
static void cleanup(int sig){if(tool_child>0)kill(tool_child,SIGTERM);if(extra_tool>0)kill(extra_tool,SIGTERM);_exit(128+sig);}
static void ready(void){if(busy_goal){puts("\n• Working (1s • esc to interrupt)\n\n› Ask Codex to do anything\n\nGoal active");if(getenv("FIXTURE_VIM_GOAL"))puts("Vim: Normal");fflush(stdout);return;}puts("\n› Ask Codex to do anything\n\n? for shortcuts");if(paused_goal)puts("Goal paused (/goal resume)");fflush(stdout);}
int main(int argc,char **argv) {
    if(argc==2&&!strcmp(argv[1],"--fixture-tool-host")){signal(SIGUSR1,linger);if(getenv("LINGER_TOOL_HOST_AFTER_EXIT"))signal(SIGHUP,SIG_IGN);for(;;)pause();}
    if(argc==2&&!strcmp(argv[1],"--fixture-login-shell")){execl("/bin/zsh","-zsh","-f","-i",NULL);return 20;}
    char db[4096],cwd[4096];getcwd(cwd,sizeof(cwd));snprintf(db,sizeof(db),"%s/logs_2.sqlite",getenv("CODEX_HOME"));
    int metadata=open(db,O_CREAT|O_RDWR,0600);if(metadata<0)return 10;
    int fd=-1;
    if(argc>1){
        if(argc!=5||strcmp(argv[1],"--remote")||strcmp(argv[2],"unix://")||strcmp(argv[3],"resume")||strcmp(argv[4],getenv("EXPECTED_THREAD")))return 12;
        struct sockaddr_un addr={0};addr.sun_family=AF_UNIX;addr.sun_len=sizeof(addr);const char *path=getenv("FIXTURE_SOCKET");
        if(!path||strlen(path)>=sizeof(addr.sun_path))return 13;strcpy(addr.sun_path,path);
        fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0||connect(fd,(struct sockaddr*)&addr,sizeof(addr)))return 14;
    }
    signal(SIGHUP,cleanup);signal(SIGTERM,cleanup);
    const char *tool=getenv("TOOL_HOST_PATH");
    if(tool&&*tool){tool_child=spawn_tool(tool);if(tool_child<0)return 24;}
    if(argc==1&&getenv("FIXTURE_ACTIVE_GOAL")){busy_goal=!getenv("FIXTURE_GOAL_IDLE")&&!getenv("FIXTURE_GOAL_PAUSED");paused_goal=getenv("FIXTURE_GOAL_PAUSED")!=NULL;struct termios mode;if(tcgetattr(0,&mode)==0){mode.c_lflag &= ~ICANON;mode.c_cc[VMIN]=1;mode.c_cc[VTIME]=0;tcsetattr(0,TCSANOW,&mode);}}
    FILE *out=fopen(getenv("READY_FILE"),"w");if(!out)return 15;fprintf(out,"%d %d\n",getpid(),argc);fclose(out);ready();
    char line[4096];while(input_line(line,sizeof(line))){
        if(!strcmp(line,"/exit\n"))break;
        if(!strcmp(line,"/fixture-finish-pause\n")){pause_goal();fputs("\033[2J\033[H",stdout);puts("Goal paused");ready();}
        if(!strcmp(line,"/goal pause\n")){pause_goal();puts("Goal paused");ready();}
        if(!strcmp(line,"/fixture-extra-host\n")&&tool&&extra_tool<0){extra_tool=spawn_tool(tool);puts("New tool host appeared");ready();}
        if(!strcmp(line,"/fixture-remove-extra-host\n")&&extra_tool>0){kill(extra_tool,SIGTERM);waitpid(extra_tool,NULL,0);extra_tool=-1;puts("New tool host finished");ready();}
        if(!strcmp(line,"/fixture-progress\n")){puts("Goal completed");ready();}
        if(!strcmp(line,"/status\n")){
            printf("\n/status\n\n  >_ OpenAI Codex (v0.166.0)\n\n  Model: synthetic\n  Directory: %s\n  Permissions: Read Only\n  Agents.md: none\n  Session: %s\n  Token usage: 0\n",cwd,getenv("STATUS_THREAD") ? getenv("STATUS_THREAD"):getenv("EXPECTED_THREAD"));ready();
        }
    }
    if(extra_tool>0){kill(extra_tool,SIGTERM);waitpid(extra_tool,NULL,0);}
    if(tool_child>0){if(getenv("LINGER_TOOL_HOST_AFTER_EXIT"))kill(tool_child,SIGUSR1);else{kill(tool_child,SIGTERM);waitpid(tool_child,NULL,0);}}
    if(fd>=0)close(fd);close(metadata);return 0;
}
