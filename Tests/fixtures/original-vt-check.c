#include "CPTY.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void feed(APVT *vt, const char *text) { ap_vt_feed(vt, text, strlen(text)); }
int main(void) {
    APVT *vt = ap_vt_new(6, 30); assert(vt);
    feed(vt, "\033[38;2;217;119;87;1mClaude \033[0m한글 🧪\r\n\033[38;2;135;215;255;48;2;48;48;48;3;4;9mCodex\033[0m");
    APVTCellInfo cell; char text[32]; APVTCursorInfo cursor;
    assert(ap_vt_cell(vt, 0, 0, &cell, text, sizeof(text)) == 1);
    assert(strcmp(text, "C") == 0 && cell.foreground == 0xd97757 && (cell.flags & 1));
    assert(ap_vt_cell(vt, 0, 7, &cell, text, sizeof(text)) == 3);
    assert(strcmp(text, "한") == 0 && cell.width == 2);
    assert(ap_vt_cell(vt, 0, 8, &cell, text, sizeof(text)) == 0 && cell.width == 0);
    assert(ap_vt_cell(vt, 1, 0, &cell, text, sizeof(text)) == 1 && cell.foreground == 0x87d7ff && cell.background == 0x303030);
    assert((cell.flags & (2 | 4 | 32)) == (2 | 4 | 32));
    ap_vt_cursor(vt, &cursor); assert(cursor.row == 1 && cursor.column == 5 && cursor.visible);
    puts("PASS original RGB/styles/wide cells/authoritative cursor");
    feed(vt, "\033[?25l\033[5 q\033[2D"); ap_vt_cursor(vt, &cursor);
    assert(!cursor.visible && cursor.shape == 3 && cursor.blink && cursor.column == 3);
    feed(vt, "\033[?1049h\033[H\033[7;8mALT\033[0m\033[?25h");
    assert(ap_vt_cell(vt, 0, 0, &cell, text, sizeof(text)) == 1 && strcmp(text, "A") == 0);
    assert((cell.flags & (8 | 16)) == (8 | 16));
    ap_vt_cursor(vt, &cursor); assert(cursor.visible);
    feed(vt, "\033[?1049l"); assert(ap_vt_cell(vt, 0, 0, &cell, text, sizeof(text)) == 1 && strcmp(text, "C") == 0);
    puts("PASS original alternate screen/hidden cursor/inverse/conceal");
    assert(ap_vt_cell(vt, -1, 0, &cell, text, sizeof(text)) == -1);
    assert(ap_vt_cell(vt, 6, 0, &cell, text, sizeof(text)) == -1);
    assert(ap_vt_cell(vt, 0, 30, &cell, text, sizeof(text)) == -1);
    assert(ap_vt_cell(vt, 0, 0, &cell, text, 1) == -1);
    ap_vt_free(vt); puts("PASS original cell bounds/UTF-8 buffer bound; no PTY was spawned"); return 0;
}
