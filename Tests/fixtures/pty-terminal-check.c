#include "CPTY.h"
#include "vterm_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static VTerm *emulator(void) {
    VTerm *vt=vterm_new(12,20); vterm_set_utf8(vt,1);
    VTermScreen *screen=vterm_obtain_screen(vt);vterm_screen_enable_altscreen(screen,1);vterm_screen_reset(screen,1);return vt;
}
static int same(VTerm *a,VTerm *b) {
    VTermScreen *sa=vterm_obtain_screen(a),*sb=vterm_obtain_screen(b);
    for(int row=0;row<12;row++)for(int col=0;col<20;col++){
        VTermScreenCell ca={0},cb={0};vterm_screen_get_cell(sa,(VTermPos){row,col},&ca);vterm_screen_get_cell(sb,(VTermPos){row,col},&cb);
        if(!ca.chars[0])ca.chars[0]=' ';if(!cb.chars[0])cb.chars[0]=' ';
        if(memcmp(ca.chars,cb.chars,sizeof(ca.chars))){fprintf(stderr,"cells differ at %d,%d: U+%x / U+%x\n",row,col,ca.chars[0],cb.chars[0]);return 0;}
        if(ca.chars[0]!=' '&&(ca.attrs.bold!=cb.attrs.bold||ca.attrs.underline!=cb.attrs.underline||ca.attrs.reverse!=cb.attrs.reverse))return 0;
        vterm_screen_convert_color_to_rgb(sa,&ca.fg);vterm_screen_convert_color_to_rgb(sb,&cb.fg);
        vterm_screen_convert_color_to_rgb(sa,&ca.bg);vterm_screen_convert_color_to_rgb(sb,&cb.bg);
        if(!vterm_color_is_equal(&ca.bg,&cb.bg)||(ca.chars[0]!=' '&&!vterm_color_is_equal(&ca.fg,&cb.fg))){fprintf(stderr,"colors differ at %d,%d: bg %d,%d,%d / %d,%d,%d; fg %d,%d,%d / %d,%d,%d\n",row,col,ca.bg.rgb.red,ca.bg.rgb.green,ca.bg.rgb.blue,cb.bg.rgb.red,cb.bg.rgb.green,cb.bg.rgb.blue,ca.fg.rgb.red,ca.fg.rgb.green,ca.fg.rgb.blue,cb.fg.rgb.red,cb.fg.rgb.green,cb.fg.rgb.blue);return 0;}
    }
    VTermState *aa=vterm_obtain_state(a),*bb=vterm_obtain_state(b);
    if(aa->pos.row!=bb->pos.row||aa->pos.col!=bb->pos.col){fprintf(stderr,"cursor differs %d,%d / %d,%d\n",aa->pos.row,aa->pos.col,bb->pos.row,bb->pos.col);return 0;}
    return aa->mode.autowrap==bb->mode.autowrap&&aa->mode.origin==bb->mode.origin&&aa->mode.insert==bb->mode.insert&&aa->mode.cursor_visible==bb->mode.cursor_visible&&aa->mode.alt_screen==bb->mode.alt_screen;
}
int main(void) {
    APVT *narrow=ap_vt_new(12,20);
    const char *dialog="Would you like to run the following command?\r\n\r\n  $ echo safe\r\n";
    ap_vt_feed(narrow,dialog,strlen(dialog));char *logical=ap_vt_text(narrow);
    int wrapped_failure=strstr(logical,"Would you like to run the following command?\n\n  $ echo safe")==NULL;
    printf("%s logical soft wraps retain actual newlines\n",wrapped_failure?"FAIL":"PASS");free(logical);ap_vt_free(narrow);
    struct {const char *name,*prefix,*tail;} cases[]={
        {"active pen","\033[1;31;48;5;17m","RED"},
        {"scroll margins","TOP\033[12;1HBOTTOM\033[3;10r\033[10;1H","A\r\nB\r\nC\r\nD"},
        {"autowrap off","\033[?7l\033[3;20HX","YZ"},
        {"partial CSI","\033[31","mRED"},
        {"partial UTF-8","\xf0\x9f","\x98\x80"},
        {"pending wrap","\033[2;20HX","YZ"},
        {"origin and insert","\033[3;10r\033[?6h\033[4h\033[2;4H","AB\033[DZ"},
        {"alternate screen and hidden cursor","\033[?1049h\033[2J\033[H\033[?25l\033[38;2;12;234;56mTUI\033[5;9H","MARK"}
    };
    int failed=wrapped_failure;
    for(size_t n=0;n<sizeof(cases)/sizeof(cases[0]);n++){
        APVT *source=ap_vt_new(12,20);VTerm *oracle=emulator(),*restored=emulator();
        ap_vt_feed(source,cases[n].prefix,strlen(cases[n].prefix));vterm_input_write(oracle,cases[n].prefix,strlen(cases[n].prefix));
        size_t snapshot_length=0;char *snapshot=ap_vt_snapshot(source,&snapshot_length);vterm_input_write(restored,snapshot,snapshot_length);free(snapshot);
        vterm_input_write(oracle,cases[n].tail,strlen(cases[n].tail));vterm_input_write(restored,cases[n].tail,strlen(cases[n].tail));
        if(!same(oracle,restored)){fprintf(stderr,"FAIL snapshot %s\n",cases[n].name);failed++;}else printf("PASS snapshot %s\n",cases[n].name);
        ap_vt_free(source);vterm_free(oracle);vterm_free(restored);
    }
    return failed?1:0;
}
