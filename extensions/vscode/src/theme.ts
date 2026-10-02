import { readFile } from 'node:fs/promises';
import * as path from 'node:path';
import { parse, ParseError } from 'jsonc-parser';
import { ansiPalette } from './screen';

type Colors = Record<string, unknown>;
export type TerminalTheme = { palette: string[]; defaults: { foreground: string; background: string }; boldIsBright: boolean };
const light = ['#000000', '#cd3131', '#107c10', '#949800', '#0451a5', '#bc05bc', '#0598bc', '#555555', '#666666', '#f14c4c', '#14ce14', '#b5ba00', '#3b8eea', '#d670d6', '#29b8db', '#a5a5a5'];
const highContrast = ['#000000', '#cd0000', '#00cd00', '#cdcd00', '#0000ee', '#cd00cd', '#00cdcd', '#e5e5e5', '#7f7f7f', '#ff0000', '#00ff00', '#ffff00', '#5c5cff', '#ff00ff', '#00ffff', '#ffffff'];
const highContrastLight = ['#292929', '#cd3131', '#136c13', '#949800', '#0451a5', '#bc05bc', '#0598bc', '#555555', '#666666', '#cd3131', '#00bc00', '#b5ba00', '#0451a5', '#bc05bc', '#0598bc', '#a5a5a5'];

export async function readThemeColors(file: string, seen = new Set<string>()): Promise<Colors> {
  if (seen.size >= 12 || seen.has(file)) { return {}; }
  seen.add(file);
  try {
    const data = await readFile(file, 'utf8');
    if (data.length > 2_000_000) { return {}; }
    const errors: ParseError[] = [], value = parse(data, errors, { allowTrailingComma: true });
    if (errors.length || !value || typeof value !== 'object') { return {}; }
    const inherited = typeof value.include === 'string' ? await readThemeColors(path.resolve(path.dirname(file), value.include), seen) : {};
    return { ...inherited, ...(value.colors && typeof value.colors === 'object' && !Array.isArray(value.colors) ? value.colors : {}) };
  } catch { return {}; }
}
function matchesTheme(key: string, name: string): boolean {
  return [...key.matchAll(/\[([^\]]+)\]/g)].some(match => {
    const pattern = match[1].split('*').map(part => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*');
    return new RegExp('^' + pattern + '$').test(name);
  });
}
function color(value: unknown, background: string): string | undefined {
  if (typeof value !== 'string' || !/^#(?:[\da-f]{3,4}|[\da-f]{6}|[\da-f]{8})$/i.test(value)) { return undefined; }
  let hex = value.slice(1);
  if (hex.length < 5) { hex = [...hex].map(char => char + char).join(''); }
  if (hex.length === 6) { return '#' + hex.toLowerCase(); }
  const alpha = parseInt(hex.slice(6), 16) / 255;
  return '#' + [0, 2, 4].map(index => Math.round(parseInt(hex.slice(index, index + 2), 16) * alpha + parseInt(background.slice(index + 1, index + 3), 16) * (1 - alpha)).toString(16).padStart(2, '0')).join('');
}
export function resolveTerminalTheme(base: Colors, custom: Colors, name: string, kind: number, inEditor = false, boldIsBright = true): TerminalTheme {
  const colors = { ...base, ...custom };
  for (const [key, value] of Object.entries(custom)) {
    if (key.startsWith('[') && matchesTheme(key, name) && value && typeof value === 'object' && !Array.isArray(value)) { Object.assign(colors, value); }
  }
  const isLight = kind === 1 || kind === 4;
  const editor = color(colors['editor.background'], isLight ? '#ffffff' : '#1e1e1e') || (isLight ? '#ffffff' : kind === 3 ? '#000000' : '#1e1e1e');
  const panel = inEditor ? editor : color(colors['panel.background'], editor) || editor;
  const background = color(colors['terminal.background'], panel) || panel;
  const foreground = color(colors['terminal.foreground'], background) || (kind === 1 ? '#333333' : kind === 4 ? '#292929' : kind === 3 ? '#ffffff' : '#cccccc');
  const palette = kind === 1 ? light : kind === 3 ? highContrast : kind === 4 ? highContrastLight : ansiPalette;
  const names = ['Black', 'Red', 'Green', 'Yellow', 'Blue', 'Magenta', 'Cyan', 'White'];
  return { palette: palette.map((fallback, index) => color(colors['terminal.ansi' + (index >= 8 ? 'Bright' : '') + names[index % 8]], background) || fallback),
    defaults: { foreground, background }, boldIsBright };
}
