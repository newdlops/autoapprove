import { Terminal } from '@xterm/headless';
import { createHash, randomUUID } from 'node:crypto';

// Offsets are UTF-16, as in the browser. Screen text remains the exact input guard.
export type TerminalRun = { offset: number; length: number; fg?: string; bg?: string; bold?: boolean; dim?: boolean; italic?: boolean; underline?: boolean; strike?: boolean; inverse?: boolean; hidden?: boolean };
export type TerminalAppearance = { runs: TerminalRun[]; foreground?: string; background?: string };
export const ansiPalette = ['#000000', '#cd3131', '#0dbc79', '#e5e510', '#2472c8', '#bc3fbc', '#11a8cd', '#e5e5e5', '#666666', '#f14c4c', '#23d18b', '#f5f543', '#3b8eea', '#d670d6', '#29b8db', '#e5e5e5'];
const rgb = (value: number) => '#' + value.toString(16).padStart(6, '0');
function paletteColor(index: number, palette: readonly string[]): string {
  if (index < 16) { return palette[index] || ansiPalette[index]; }
  if (index >= 232) { const value = 8 + (index - 232) * 10; return rgb((value << 16) | (value << 8) | value); }
  const value = index - 16, levels = [0, 95, 135, 175, 215, 255];
  return rgb((levels[Math.floor(value / 36)] << 16) | (levels[Math.floor(value / 6) % 6] << 8) | levels[value % 6]);
}

export class ScreenMirror {
  readonly generation = randomUUID();
  readonly terminal = new Terminal({ cols: 120, rows: 40, scrollback: 0, allowProposedApi: true });
  valid = true;
  private attempted = new Set<string>();
  private writeQueue: Promise<void> = Promise.resolve();
  private pendingWrites = 0;
  private revision = 0;
  private appearanceCache?: { revision: number; theme: string; value: TerminalAppearance | undefined };

  write(data: string): Promise<void> {
    this.pendingWrites++;
    this.writeQueue = this.writeQueue.then(() => new Promise<void>(resolve => {
      this.terminal.write(data, () => { this.pendingWrites--; this.revision++; resolve(); });
    }));
    return this.writeQueue;
  }
  resize(columns: number, rows: number): void {
    if (!Number.isInteger(columns) || !Number.isInteger(rows) || columns < 10 || columns > 500 || rows < 3 || rows > 300) { return; }
    if (this.terminal.cols !== columns || this.terminal.rows !== rows) { this.terminal.resize(columns, rows); this.revision++; }
  }
  snapshot(): string {
    const buffer = this.terminal.buffer.active;
    const lines: string[] = [];
    for (let row = buffer.baseY; row < buffer.baseY + this.terminal.rows; row++) {
      lines.push(buffer.getLine(row)?.translateToString(true) ?? '');
    }
    return lines.join('\n');
  }
  appearance(palette: readonly string[] = ansiPalette, defaults: { foreground?: string; background?: string } = {}, boldIsBright = true): TerminalAppearance | undefined {
    const theme = JSON.stringify([palette, defaults, boldIsBright]);
    if (this.appearanceCache?.revision === this.revision && this.appearanceCache.theme === theme) { return this.appearanceCache.value; }
    const buffer = this.terminal.buffer.active, cell = buffer.getNullCell();
    const runs: TerminalRun[] = [];
    let offset = 0, previousKey = '';
    for (let row = buffer.baseY; row < buffer.baseY + this.terminal.rows; row++) {
      const line = buffer.getLine(row), text = line?.translateToString(true) ?? '';
      let length = 0;
      for (let col = 0; line && col < line.length && length < text.length; col++) {
        line.getCell(col, cell);
        if (cell.getWidth() === 0) { continue; }
        const chars = cell.getChars() || ' ', count = Math.min(chars.length, text.length - length);
        const style: Omit<TerminalRun, 'offset' | 'length'> = {};
        if (cell.isFgRGB()) { style.fg = rgb(cell.getFgColor()); }
        else if (cell.isFgPalette()) { const index = cell.getFgColor(); style.fg = paletteColor(index < 8 && cell.isBold() && boldIsBright ? index + 8 : index, palette); }
        if (cell.isBgRGB()) { style.bg = rgb(cell.getBgColor()); }
        else if (cell.isBgPalette()) { style.bg = paletteColor(cell.getBgColor(), palette); }
        if (cell.isBold()) { style.bold = true; }
        if (cell.isDim()) { style.dim = true; }
        if (cell.isItalic()) { style.italic = true; }
        if (cell.isUnderline()) { style.underline = true; }
        if (cell.isStrikethrough()) { style.strike = true; }
        if (cell.isInverse()) { style.inverse = true; }
        if (cell.isInvisible()) { style.hidden = true; }
        const key = JSON.stringify(style), last = runs[runs.length - 1];
        if (key !== '{}') {
          if (last && key === previousKey && last.offset + last.length === offset + length) { last.length += count; }
          else { runs.push({ offset: offset + length, length: count, ...style }); }
          if (runs.length > 8000) { this.appearanceCache = { revision: this.revision, theme, value: undefined }; return undefined; }
        }
        previousKey = key; length += count;
      }
      offset += text.length + 1;
    }
    const value = { runs, ...defaults };
    this.appearanceCache = { revision: this.revision, theme, value };
    return value;
  }
  fingerprint(): string { return createHash('sha256').update(this.snapshot()).digest('hex'); }
  consumeInput(action: Record<string, unknown>, now = Date.now()): boolean {
    if (!this.valid || this.pendingWrites !== 0 || typeof action.id !== 'string' || this.attempted.has(action.id)
      || action.generation !== this.generation || typeof action.expiresAt !== 'number' || action.expiresAt < now || action.expiresAt > now + 5000
      || typeof action.screen !== 'string' || action.screen !== this.snapshot() || typeof action.kind !== 'string') { return false; }
    if (['text', 'submit', 'characters'].includes(action.kind)) {
      if (typeof action.text !== 'string' || !action.text || Buffer.byteLength(action.text) > 8000 || /[\x00-\x08\x0b-\x1f\x7f]/.test(action.text)
        || action.kind === 'characters' && /[\n\t]/.test(action.text)) { return false; }
    } else if (!['enter', 'escape', 'interrupt', 'up', 'down', 'left', 'right', 'backspace', 'delete', 'home', 'end', 'tab'].includes(action.kind) || action.text !== '') { return false; }
    this.attempted.add(action.id);
    if (this.attempted.size > 512) { this.attempted.delete(this.attempted.values().next().value!); }
    return true;
  }
  consume(action: { id: string; fingerprint: string; dialog?: string; agent?: string; generation: string; expiresAt: number; answer: string }, now = Date.now()): boolean {
    if (!this.valid || this.pendingWrites !== 0 || action.generation !== this.generation || action.expiresAt < now || action.expiresAt > now + 5000 || action.answer !== '1') { return false; }
    if (this.attempted.has(action.id)) { return false; }
    if (action.dialog !== undefined) {
      const normalize = (text: string) => text.normalize('NFC').replace(/\r\n?/g, '\n');
      const lines = normalize(this.snapshot()).split('\n');
      while (lines.length && !lines[lines.length - 1].trim()) { lines.pop(); }
      const expected = normalize(action.dialog);
      let start = 0;
      if (action.agent !== 'claude') {
        const heading = expected.split('\n')[0].trim();
        start = -1;
        for (let index = 0; index < lines.length; index++) { if (lines[index].trim() === heading) { start = index; } }
      }
      if (start < 0 || lines.slice(start).join('\n') !== expected) { return false; }
    } else if (action.fingerprint !== this.fingerprint()) { return false; }
    this.attempted.add(action.id);
    if (this.attempted.size > 512) { this.attempted.delete(this.attempted.values().next().value!); }
    return true;
  }
  invalidate(): void { this.valid = false; }
  dispose(): void { this.valid = false; void this.writeQueue.then(() => this.terminal.dispose()); }
}
