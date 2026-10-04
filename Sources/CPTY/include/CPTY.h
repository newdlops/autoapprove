#ifndef AUTOAPPROVE_CPTY_H
#define AUTOAPPROVE_CPTY_H
#include <stddef.h>
#include <stdint.h>
int ap_pty_spawn(const char *cwd, char *const argv[], char *const env[], int rows, int columns, int *pid, int *master, char *tty);
int ap_pty_resize(int master, int rows, int columns);
typedef struct APVT APVT;
APVT *ap_vt_new(int rows, int columns);
void ap_vt_free(APVT *vt);
void ap_vt_feed(APVT *vt, const char *data, size_t length);
void ap_vt_resize(APVT *vt, int rows, int columns);
size_t ap_vt_response(APVT *vt, char *buffer, size_t length);
char *ap_vt_text(APVT *vt);
char *ap_vt_snapshot(APVT *vt, size_t *length);
#endif
