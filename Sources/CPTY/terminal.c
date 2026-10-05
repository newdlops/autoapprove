#include "CPTY.h"
#include "vterm.h"
#include "vterm_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct APVT {
    VTerm *term; VTermScreen *screen; int rows, columns;
    char *pending; size_t pending_length, pending_capacity; int pending_overflow;
};
APVT *ap_vt_new(int rows, int columns) {
    APVT *result = calloc(1, sizeof(APVT)); if (!result) return NULL;
    result->term = vterm_new(rows, columns); if (!result->term) { free(result); return NULL; }
    result->screen = vterm_obtain_screen(result->term); result->rows = rows; result->columns = columns;
    vterm_set_utf8(result->term, 1); vterm_screen_enable_altscreen(result->screen, 1);
    vterm_screen_reset(result->screen, 1); return result;
}
void ap_vt_free(APVT *vt) { if (vt) { vterm_free(vt->term); free(vt->pending); free(vt); } }
static int parser_complete(APVT *vt) {
    // UTF8DecoderData.bytes_remaining is the first integer in the pinned encoder.
    int remaining=0; memcpy(&remaining,vt->term->state->encoding_utf8.data,sizeof(remaining));
    return vt->term->parser.state==NORMAL && !vt->term->parser.in_esc && !remaining;
}
static void pending_byte(APVT *vt, unsigned char c) {
    if(vt->pending_overflow)return;
    if(vt->pending_length==vt->pending_capacity){
        size_t capacity=vt->pending_capacity?vt->pending_capacity*2:64;
        if(capacity>1048576){vt->pending_overflow=1;return;}
        char *next=realloc(vt->pending,capacity);if(!next){vt->pending_overflow=1;return;}
        vt->pending=next;vt->pending_capacity=capacity;
    }
    vt->pending[vt->pending_length++]=c;
}
void ap_vt_feed(APVT *vt, const char *data, size_t length) {
    size_t pos=0;
    while(pos<length){
        unsigned char c=data[pos];
        if(!vt->pending_length&&!vt->pending_overflow&&c!=0x1b&&c<0x80){
            size_t start=pos++;while(pos<length&&(unsigned char)data[pos]<0x80&&data[pos]!=0x1b)pos++;
            vterm_input_write(vt->term,data+start,pos-start);continue;
        }
        if(c==0x1b&&vt->term->parser.state<OSC_COMMAND){vt->pending_length=0;vt->pending_overflow=0;}
        // C0 effects are already represented in the saved cursor/cells. Retain
        // the incomplete sequence itself without executing those effects twice.
        if(c>=0x20||c==0x1b)pending_byte(vt,c);
        vterm_input_write(vt->term,data+pos++,1);
        if(parser_complete(vt)){vt->pending_length=0;vt->pending_overflow=0;}
    }
    vterm_screen_flush_damage(vt->screen);
}
void ap_vt_resize(APVT *vt, int rows, int columns) { vt->rows = rows; vt->columns = columns; vterm_set_size(vt->term, rows, columns); }
size_t ap_vt_response(APVT *vt, char *buffer, size_t length) { return vterm_output_read(vt->term, buffer, length); }
char *ap_vt_text(APVT *vt) {
    size_t capacity = (size_t)vt->rows * vt->columns * 32 + vt->rows + 1;
    char *text = calloc(capacity, 1); if (!text) return NULL;
    size_t length=0;VTermState *state=vterm_obtain_state(vt->term);
    for(int row=0;row<vt->rows;row++){
        if(row&&!vterm_state_get_lineinfo(state,row)->continuation)text[length++]='\n';
        length+=vterm_screen_get_text(vt->screen,text+length,capacity-length-1,(VTermRect){row,row+1,0,vt->columns});
    }
    text[length] = 0; return text;
}
static int codepoint(char *out, uint32_t value) {
    if (value < 0x80) { out[0] = value; return 1; }
    if (value < 0x800) { out[0] = 0xc0 | (value >> 6); out[1] = 0x80 | (value & 63); return 2; }
    if (value < 0x10000) { out[0] = 0xe0 | (value >> 12); out[1] = 0x80 | ((value >> 6) & 63); out[2] = 0x80 | (value & 63); return 3; }
    out[0] = 0xf0 | (value >> 18); out[1] = 0x80 | ((value >> 12) & 63); out[2] = 0x80 | ((value >> 6) & 63); out[3] = 0x80 | (value & 63); return 4;
}
// Inspect an owner-provided ANSI snapshot without opening or writing a PTY.
int ap_vt_cell(APVT *vt, int row, int column, APVTCellInfo *info, char *text, size_t capacity) {
    if (!vt || !info || !text || capacity < 2 || row < 0 || row >= vt->rows || column < 0 || column >= vt->columns) return -1;
    VTermScreenCell cell; memset(&cell, 0, sizeof(cell)); memset(info, 0, sizeof(*info)); text[0] = 0;
    if (!vterm_screen_get_cell(vt->screen, (VTermPos){row, column}, &cell)) return -1;
    if (cell.chars[0] == (uint32_t)-1) return 0;
    info->width = cell.width ? cell.width : 1;
    info->flags = (cell.attrs.bold ? 1 : 0) | (cell.attrs.italic ? 2 : 0) | (cell.attrs.underline ? 4 : 0)
        | (cell.attrs.reverse ? 8 : 0) | (cell.attrs.conceal ? 16 : 0) | (cell.attrs.strike ? 32 : 0);
    info->foreground_default = VTERM_COLOR_IS_DEFAULT_FG(&cell.fg); info->background_default = VTERM_COLOR_IS_DEFAULT_BG(&cell.bg);
    VTermColor fg = cell.fg, bg = cell.bg;
    vterm_screen_convert_color_to_rgb(vt->screen, &fg); vterm_screen_convert_color_to_rgb(vt->screen, &bg);
    info->foreground = ((uint32_t)fg.rgb.red << 16) | ((uint32_t)fg.rgb.green << 8) | fg.rgb.blue;
    info->background = ((uint32_t)bg.rgb.red << 16) | ((uint32_t)bg.rgb.green << 8) | bg.rgb.blue;
    size_t length = 0;
    if (!cell.chars[0]) { text[length++] = ' '; }
    else for (int index = 0; index < VTERM_MAX_CHARS_PER_CELL && cell.chars[index]; index++) {
        char encoded[4]; int size = codepoint(encoded, cell.chars[index]);
        if (length + size >= capacity) return -1;
        memcpy(text + length, encoded, size); length += size;
    }
    text[length] = 0; return (int)length;
}
void ap_vt_cursor(APVT *vt, APVTCursorInfo *info) {
    if (!vt || !info) return;
    VTermState *state = vterm_obtain_state(vt->term); VTermPos cursor;
    vterm_state_get_cursorpos(state, &cursor);
    *info = (APVTCursorInfo){cursor.row, cursor.col, state->mode.cursor_visible, state->mode.cursor_shape, state->mode.cursor_blink};
}
// Reconnection restores current cells and modes, never historical terminal queries.
// libvterm alone answers queries to the PTY; browser renderers must not answer twice.
static size_t cell_style(char *out,size_t capacity,const VTermScreenCell *cell) {
    size_t n=snprintf(out,capacity,"\033[0%s%s%s%s%s%sm",cell->attrs.bold?";1":"",cell->attrs.italic?";3":"",cell->attrs.underline==VTERM_UNDERLINE_DOUBLE?";21":cell->attrs.underline==VTERM_UNDERLINE_CURLY?";4:3":cell->attrs.underline?";4":"",cell->attrs.blink?";5":"",cell->attrs.reverse?";7":"",cell->attrs.strike?";9":"");
    for(int bg=0;bg<2;bg++){
        VTermColor color=bg?cell->bg:cell->fg;
        if(bg?VTERM_COLOR_IS_DEFAULT_BG(&color):VTERM_COLOR_IS_DEFAULT_FG(&color))continue;
        if(VTERM_COLOR_IS_INDEXED(&color))n+=snprintf(out+n,capacity-n,"\033[%d;5;%dm",bg?48:38,color.indexed.idx);
        else n+=snprintf(out+n,capacity-n,"\033[%d;2;%d;%d;%dm",bg?48:38,color.rgb.red,color.rgb.green,color.rgb.blue);
    }
    return n;
}
char *ap_vt_snapshot(APVT *vt, size_t *length) {
    if(vt->pending_overflow)return NULL;
    size_t capacity = (size_t)vt->rows * vt->columns * 128 + vt->pending_length + 8192;
    char *out = calloc(capacity, 1); if (!out) return NULL;
    VTermState *state = vterm_obtain_state(vt->term);
    size_t n = snprintf(out, capacity, "\033c\033[?%dh\033[?25l\033[?7h\033[0m\033[2J", state->mode.alt_screen ? 1049 : 7);
    for (int row = 0; row < vt->rows; row++) {
        if(!row||!vterm_state_get_lineinfo(state,row)->continuation)n += snprintf(out + n, capacity - n, "\033[%d;1H", row + 1);
        VTermScreenCell previous; memset(&previous, 0xff, sizeof(previous));
        for (int col = 0; col < vt->columns; col++) {
            VTermScreenCell cell; memset(&cell, 0, sizeof(cell));
            vterm_screen_get_cell(vt->screen, (VTermPos){row, col}, &cell);
            if (cell.chars[0] == (uint32_t)-1) continue; // continuation of a wide character
            if (memcmp(&cell.attrs, &previous.attrs, sizeof(cell.attrs)) || !vterm_color_is_equal(&cell.fg, &previous.fg) || !vterm_color_is_equal(&cell.bg, &previous.bg)) {
                n += cell_style(out+n,capacity-n,&cell);
                previous = cell;
            }
            if (!cell.chars[0]) out[n++] = ' ';
            else for (int c = 0; c < VTERM_MAX_CHARS_PER_CELL && cell.chars[c]; c++) n += codepoint(out + n, cell.chars[c]);
        }
    }
    VTermPos cursor; vterm_state_get_cursorpos(state, &cursor);
    n+=snprintf(out+n,capacity-n,"\033[%d;%dr\033[?6%c\033[?7%c\033[%d;%dH",state->scrollregion_top+1,SCROLLREGION_BOTTOM(state),state->mode.origin?'h':'l',state->mode.autowrap?'h':'l',cursor.row+1-(state->mode.origin?state->scrollregion_top:0),cursor.col+1);
    if(state->at_phantom&&state->mode.autowrap){
        VTermScreenCell cell;int col=cursor.col;vterm_screen_get_cell(vt->screen,(VTermPos){cursor.row,col},&cell);
        if(cell.chars[0]==(uint32_t)-1&&col>0)vterm_screen_get_cell(vt->screen,(VTermPos){cursor.row,--col},&cell);
        n+=snprintf(out+n,capacity-n,"\033[%d;%dH",cursor.row+1-(state->mode.origin?state->scrollregion_top:0),col+1);
        n+=cell_style(out+n,capacity-n,&cell);
        for(int c=0;c<VTERM_MAX_CHARS_PER_CELL&&cell.chars[c];c++)n+=codepoint(out+n,cell.chars[c]);
    }
    n+=snprintf(out+n,capacity-n,"\033[4%c\033[20%c\033[?1%c\033[?2004%c\033[?1004%c\033[?25%c\033[%d q\033%c",state->mode.insert?'h':'l',state->mode.newline?'h':'l',state->mode.cursor?'h':'l',state->mode.bracketpaste?'h':'l',state->mode.report_focus?'h':'l',state->mode.cursor_visible?'h':'l',state->mode.cursor_shape==2?(state->mode.cursor_blink?3:4):state->mode.cursor_shape==3?(state->mode.cursor_blink?5:6):(state->mode.cursor_blink?1:2),state->mode.keypad?'=':'>');
    long pen[64];int count=vterm_state_getpen(state,pen,64);
    n+=snprintf(out+n,capacity-n,"\033[0");for(int i=0;i<count;i++)n+=snprintf(out+n,capacity-n,"%c%ld",i&&CSI_ARG_HAS_MORE(pen[i-1])?':':';',CSI_ARG(pen[i]));out[n++]='m';
    memcpy(out+n,vt->pending,vt->pending_length);n+=vt->pending_length;
    out[n]=0;*length=n;return out;
}
