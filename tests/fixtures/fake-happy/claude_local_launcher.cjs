// Fake claude_local_launcher: keeps claude alive. If claude dies while the
// launcher still runs, it starts a new one (the real launcher's loop does this),
// which is why sessionctl must stop the launcher before claude.
const { spawn } = require('node:child_process');
const path = require('node:path');
const claude = path.join(__dirname, '..', '..', '..', 'claude', 'claude.exe');
let stopping = false;
function run() {
  const child = spawn(process.execPath, [claude, ...process.argv.slice(2)], { stdio: 'inherit' });
  child.on('exit', () => { if (!stopping) setTimeout(run, 200); });
}
process.on('SIGTERM', () => { stopping = true; process.exit(0); });
run();
