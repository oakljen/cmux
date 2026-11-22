// Copies a built cmux-tui binary to the name Tauri's externalBin expects:
//   binaries/cmux-tui-<target-triple>[.exe]
// Usage: node scripts/prepare-sidecar.mjs [path-to-cmux-tui[.exe]]
import { execSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const triple = execSync('rustc -vV').toString().match(/host: (\S+)/)[1];
const exe = triple.includes('windows') ? '.exe' : '';
const tui = resolve(here, '../../../');
const candidates = [
  process.argv[2],
  join(tui, 'target/release', `cmux-tui${exe}`),
  join(tui, 'target/debug', `cmux-tui${exe}`),
].filter(Boolean);
const src = candidates.find((p) => existsSync(p));
if (!src) {
  console.error('No cmux-tui binary found. Build it first: cargo build -p cmux-tui --release');
  process.exit(1);
}
const outDir = resolve(here, '../src-tauri/binaries');
mkdirSync(outDir, { recursive: true });
const dest = join(outDir, `cmux-tui-${triple}${exe}`);
copyFileSync(src, dest);
console.log(`sidecar: ${src} -> ${dest}`);
