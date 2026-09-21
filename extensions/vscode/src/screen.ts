import { Terminal } from '@xterm/headless';
import { createHash, randomUUID } from 'node:crypto';

export class ScreenMirror {
  readonly generation = randomUUID();
  readonly terminal = new Terminal({ cols: 120, rows: 40, scrollback: 0, allowProposedApi: true });
  valid = true;
  private attempted = new Set<string>();
  private writeQueue: Promise<void> = Promise.resolve();
  private pendingWrites = 0;

  write(data: string): Promise<void> {
    this.pendingWrites++;
    this.writeQueue = this.writeQueue.then(() => new Promise<void>(resolve => {
      this.terminal.write(data, () => { this.pendingWrites--; resolve(); });
    }));
    return this.writeQueue;
  }
  resize(columns: number, rows: number): void {
    if (!Number.isInteger(columns) || !Number.isInteger(rows) || columns < 10 || columns > 500 || rows < 3 || rows > 300) { return; }
    if (this.terminal.cols !== columns || this.terminal.rows !== rows) { this.terminal.resize(columns, rows); }
  }
  snapshot(): string {
    const buffer = this.terminal.buffer.active;
    const lines: string[] = [];
    for (let row = buffer.baseY; row < buffer.baseY + this.terminal.rows; row++) {
      lines.push(buffer.getLine(row)?.translateToString(true) ?? '');
    }
    return lines.join('\n');
  }
  fingerprint(): string { return createHash('sha256').update(this.snapshot()).digest('hex'); }
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
