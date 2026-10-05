import { randomUUID } from 'node:crypto';

/** A native image identifies a terminal object, not a reconstructed text snapshot. */
export class NativeTerminalBinding {
  generation = randomUUID();
  selected = false;
  private confirmed = false;
  private attempted = new Set<string>();

  confirm(selected: boolean): void {
    this.confirmed = true; this.selected = selected; this.generation = randomUUID();
  }
  updateSelection(selected: boolean): void {
    const current = this.confirmed && selected;
    if (this.selected !== current) { this.selected = current; this.generation = randomUUID(); }
  }
  disconnect(): void {
    this.confirmed = false; this.selected = false; this.generation = randomUUID();
  }
  beginReveal(action: Record<string, unknown>, now = Date.now()): ((now?: number) => boolean) | undefined {
    if (typeof action.id !== 'string' || !action.id || action.id.length > 256 || this.attempted.has(action.id)
      || action.generation !== this.generation || typeof action.expiresAt !== 'number'
      || !Number.isFinite(action.expiresAt) || action.expiresAt < now || action.expiresAt > now + 5000) { return undefined; }
    this.attempted.add(action.id);
    if (this.attempted.size > 512) { this.attempted.delete(this.attempted.values().next().value!); }
    this.confirmed = false; this.selected = false; this.generation = randomUUID();
    const generation = this.generation, expiresAt = action.expiresAt;
    return (time = Date.now()) => this.generation === generation && time <= expiresAt;
  }
  consume(action: Record<string, unknown>, now = Date.now()): boolean {
    if (!this.selected || action.relay !== true || typeof action.id !== 'string' || !action.id || this.attempted.has(action.id)
      || action.generation !== this.generation || typeof action.expiresAt !== 'number' || action.expiresAt < now || action.expiresAt > now + 5000) { return false; }
    if (action.kind === 'characters') {
      if (typeof action.text !== 'string' || !action.text || Buffer.byteLength(action.text) > 8000 || /[\x00-\x1f\x7f]/.test(action.text)) { return false; }
    } else if (!['enter', 'escape', 'interrupt', 'up', 'down', 'left', 'right', 'backspace', 'delete', 'home', 'end', 'tab'].includes(String(action.kind)) || action.text !== '') { return false; }
    this.attempted.add(action.id);
    if (this.attempted.size > 512) { this.attempted.delete(this.attempted.values().next().value!); }
    return true;
  }
}
