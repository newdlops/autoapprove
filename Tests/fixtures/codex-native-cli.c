// Owned metadata-only CLI for execution-context tests; never reads credentials.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static void string(const char *s){putchar('"');for(;s&&*s;s++){if(*s=='"'||*s=='\\')putchar('\\');putchar(*s);}putchar('"');}
int main(int argc,char **argv){
 if(argc==2&&!strcmp(argv[1],"--hold")){sleep(30);return 0;}
 const char *log=getenv("AA_CLI_FIXTURE_LOG"),*home=getenv("CODEX_HOME");if(!log||!home)return 66;
 const char *expected=getenv("AA_EXPECT_PATH");if(expected&&strcmp(expected,getenv("PATH")?getenv("PATH"):""))return 72;
 expected=getenv("AA_EXPECT_HOME");if(expected&&strcmp(expected,getenv("HOME")?getenv("HOME"):""))return 73;
 expected=getenv("AA_EXPECT_CODEX_HOME");if(expected){struct stat wanted,actual;if(stat(expected,&wanted)||stat(home,&actual)||wanted.st_dev!=actual.st_dev||wanted.st_ino!=actual.st_ino)return 74;}
 const char *login=getenv("AA_EXPECT_LOGIN");
 if(login){
  if(getenv("AUTOAPPROVE_NATIVE_RUNTIME_ROOT")||getenv("AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"))return 75;
  if(!strcmp(login,"browser")&&(getenv("BROWSER")||getenv("SSH_CONNECTION")||getenv("SSH_TTY")||getenv("SSH_CLIENT")))return 76;
  if(!strcmp(login,"device")&&(!getenv("BROWSER")||strcmp(getenv("BROWSER"),"true")))return 77;
 }
 FILE *f=fopen(log,"a");if(!f)return 67;for(int i=1;i<argc;i++)fprintf(f,"%s%s",i>1?" ":"",argv[i]);fprintf(f,"\n");fclose(f);
 if(argc==2&&!strcmp(argv[1],"--version")){puts("codex-cli 0.166.0");return 0;}
 if(argc==4&&!strcmp(argv[1],"app-server")&&!strcmp(argv[2],"daemon")&&!strcmp(argv[3],"version")){
  fputs("{\"status\":\"running\",\"backend\":\"pid\",\"cliVersion\":\"0.166.0\",\"appServerVersion\":\"0.166.0\",\"managedCodexVersion\":\"0.166.0\",\"managedCodexPath\":",stdout);string(argv[0]);fputs(",\"socketPath\":",stdout);
  char path[8192];snprintf(path,sizeof(path),"%s/app-server-control/app-server-control.sock",home);string(path);puts("}");return 0;
 }
 if(argc==3&&!strcmp(argv[1],"features")&&!strcmp(argv[2],"list")){puts("daemon_auto_start stable true");return 0;}
 if(argc==3&&!strcmp(argv[1],"login")&&!strcmp(argv[2],"status")){puts("Logged in using ChatGPT");return 0;}
 if(login&&(!strcmp(login,"browser")?argc==2:argc==3&&!strcmp(argv[2],"--device-auth"))&&!strcmp(argv[1],"login")){puts("Owned login fixture completed");return 0;}
 return 68;
}

