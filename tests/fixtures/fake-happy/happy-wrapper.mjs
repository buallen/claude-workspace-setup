// Fake happy wrapper (stands in for node_modules/happy/dist/index.mjs).
// Reproduces the real behaviour sessionctl has to cope with:
//  - it spawns the claude launcher with an inherited tty,
//  - it logs "[SESSION_SCANNER] New session: <uuid>" like happy does,
//  - on SIGTERM it exits WITHOUT killing its children (real happy 1.2.5 does
//    the same: cleanup() ends in process.exit and never aborts claude).
import { spawn } from 'node:child_process';
import { mkdirSync, appendFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const i = args.indexOf('--resume');
const uuid = i >= 0 ? args[i + 1] : '00000000-0000-4000-8000-000000000000';
const logs = join(process.env.HOME, '.happy', 'logs');
mkdirSync(logs, { recursive: true });
const log = join(logs, `2026-01-01-00-00-00-pid-${process.pid}.log`);
appendFileSync(log, `[00:00:00.000] [SESSION_SCANNER] New session: ${uuid}\n`);

const here = dirname(fileURLToPath(import.meta.url));
const launcher = join(here, '..', 'scripts', 'claude_local_launcher.cjs');
spawn(process.execPath, [launcher, '--resume', uuid], { stdio: 'inherit' });
process.on('SIGTERM', () => process.exit(0));
setInterval(() => {}, 1000);
