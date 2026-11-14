import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { access, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const driver = process.argv[2];
if (!driver || typeof WebSocket === 'undefined') {
  throw new Error('Pass the compiled driver and use Node.js 22 or later');
}
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const here = dirname(fileURLToPath(import.meta.url));
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const caseNames = [
  'Original A/B setup input', 'A/B/A: first A', 'A/B/A: B', 'A/B/A: final A',
  'Identical titles: retained B identity', 'Identical titles: retained A identity',
  'Closed B with identical-title replacement did not retarget input',
];
function native(...args) {
  const result = spawnSync(driver, args.map(String), { encoding: 'utf8', timeout: 12_000 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stdout.trim() || result.stderr.trim());
  return JSON.parse(result.stdout);
}
const check = spawnSync(driver, ['preflight'], { encoding: 'utf8', timeout: 5_000 });
if (check.status === 77) {
  process.stdout.write(check.stdout);
  const skippedDirectory = await mkdtemp(join(tmpdir(), 'infinitedesk-desktop-acceptance-'));
  const skippedReport = join(skippedDirectory, 'report.json');
  await writeFile(skippedReport, JSON.stringify({
    status: 'SKIP', at: new Date().toISOString(), prerequisites: JSON.parse(check.stdout),
    platform: process.platform, architecture: process.arch, node: process.version,
    fixturesLaunched: false, managerActionsSent: false,
    cases: Object.fromEntries(caseNames.map(name => [name, 'NOT_RUN'])),
    unverified: ['All live focus, registration, typing, same-title and closed-target cases; fixture launch was skipped'],
  }, null, 2));
  console.log(`SKIP evidence: ${skippedReport}`);
  process.exit(77);
}
if (check.error || check.status !== 0) throw check.error ?? new Error(check.stderr);
await access(chrome, constants.X_OK);

class CDP {
  #socket;
  #pending = new Map();
  #next = 0;
  async connect(address) {
    const url = new URL(address);
    assert.equal(url.hostname, '127.0.0.1', 'Only the disposable loopback DevTools endpoint is allowed');
    this.#socket = new WebSocket(url);
    this.#socket.addEventListener('message', event => {
      const result = JSON.parse(String(event.data));
      const request = this.#pending.get(result.id);
      if (!request) return;
      clearTimeout(request.timer);
      this.#pending.delete(result.id);
      if (result.error) request.reject(new Error(JSON.stringify(result.error)));
      else request.resolve(result.result);
    });
    this.#socket.addEventListener('close', () => {
      for (const request of this.#pending.values()) {
        clearTimeout(request.timer);
        request.reject(new Error('Disposable Chrome DevTools connection closed'));
      }
      this.#pending.clear();
    });
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('DevTools connect timed out')), 8_000);
      this.#socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
      this.#socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('DevTools connect failed')); }, { once: true });
    });
  }
  send(method, params = {}, sessionId) {
    if (!this.#socket || this.#socket.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error('Disposable DevTools is not connected'));
    }
    const id = ++this.#next;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.#pending.delete(id); reject(new Error(`${method} timed out`)); }, 8_000);
      this.#pending.set(id, { resolve, reject, timer });
      try { this.#socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) })); }
      catch (error) { clearTimeout(timer); this.#pending.delete(id); reject(error); }
    });
  }
  disconnect() { this.#socket?.close(); }
}

const directory = await mkdtemp(join(tmpdir(), 'infinitedesk-desktop-acceptance-'));
const report = {
  status: 'RUNNING', started: new Date().toISOString(),
  platform: process.platform, architecture: process.arch, node: process.version,
  directory, prerequisites: JSON.parse(check.stdout),
  scope: 'Real desktop manager keyboard shortcuts; disposable Chrome only',
  checkpoints: [],
  inputEvidence: [],
  cases: Object.fromEntries(caseNames.map(name => [name, 'NOT_RUN'])),
  unverified: [
    'Delayed stale completion: not injected into the production app; consult backend test results separately',
    'Finder and Dock ordinary input: requires a separate manual observation',
    'Zero native frame writes: not counted by this harness; actual frames are checked and backend test results are separate evidence',
  ],
};
console.log(`Disposable Chrome and acceptance evidence: ${directory}`);
const log = await import('node:fs').then(fs => fs.openSync(join(directory, 'chrome.log'), 'w'));
const child = spawn(chrome, [
  `--user-data-dir=${join(directory, 'profile')}`, '--no-first-run', '--no-default-browser-check',
  '--disable-background-networking', '--disable-sync', '--remote-debugging-address=127.0.0.1',
  '--remote-debugging-port=0', '--new-window', 'about:blank',
], { stdio: ['ignore', log, log] });
let childError;
child.on('error', error => { childError = error; });
const cdp = new CDP();
const targets = {};
let pid;
let browserIdentityVerified = false;

async function eventually(description, operation, predicate, timeout = 5_000) {
  const deadline = Date.now() + timeout;
  let last;
  do {
    last = await operation();
    if (predicate(last)) return last;
    await pause(75);
  } while (Date.now() < deadline);
  throw new Error(`${description}: ${JSON.stringify(last)}`);
}
async function evaluate(target, expression) {
  const result = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, target.sessionId);
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
async function createTarget(name, bounds) {
  const url = new URL(pathToFileURL(join(here, 'fixture.html')));
  url.searchParams.set('id', name === 'replacement' ? 'B' : name);
  const { targetId } = await cdp.send('Target.createTarget', { url: url.href, newWindow: true });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  const target = { targetId, sessionId };
  await eventually('Fixture DOM did not become ready', () => evaluate(target, 'document.readyState'), value => value === 'complete');
  const { windowId } = await cdp.send('Browser.getWindowForTarget', { targetId });
  await cdp.send('Browser.setWindowBounds', { windowId, bounds: { windowState: 'normal' } });
  await cdp.send('Browser.setWindowBounds', { windowId, bounds });
  targets[name] = target;
  return target;
}
function snapshot() { return native('snapshot', pid); }
function sameFrame(a, b) {
  return ['x', 'y', 'width', 'height'].every(key => Math.abs(a[key] - b[key]) <= 1);
}
function unchanged(snapshot, baseline) {
  for (const window of baseline) {
    const current = snapshot.windows.find(item => item.id === window.id);
    assert(current, `Registered CG window ${window.id} is missing`);
    assert(sameFrame(current.frame, window.frame), `Native frame changed for ${window.id}: ${JSON.stringify(current.frame)}`);
  }
}
const expected = { A: 'TARGET-A', B: 'TARGET-B' };
const counts = { A: 0, B: 0 };
async function values(name) {
  return evaluate(targets[name], `({target: document.querySelector('#target').value,
    decoy: document.querySelector('#decoy').value, output: document.querySelector('#value').textContent,
    count: Number(document.querySelector('#count').textContent), focused: document.hasFocus(),
    active: document.activeElement?.id})`);
}
async function validateValues(names = ['A', 'B']) {
  const result = {};
  for (const name of names) {
    result[name] = await values(name);
    assert.equal(result[name].target, expected[name], `Wrong original ${name} DOM value`);
    assert.equal(result[name].output, expected[name], `Original ${name} input event did not update the page`);
    assert.equal(result[name].decoy, `DECOY-${name}`, `Original ${name} decoy was changed`);
    assert(result[name].count >= counts[name], `Original ${name} input event was not observed`);
  }
  return result;
}
async function typeToken(name, id, suffix) {
  const beforeNative = snapshot();
  assert.equal(beforeNative.frontmostPID, pid, 'Typing must not activate the application');
  assert.equal(beforeNative.focusedID, id, 'Typing must not select the destination window');
  const beforeDOM = await values(name);
  assert.equal(beforeDOM.focused, true, `Original ${name} did not have native page focus before typing`);
  assert.equal(beforeDOM.active, 'target', `Original ${name} target was not already the active field`);
  report.inputEvidence.push({ at: new Date().toISOString(), name, id, token: suffix, beforeNative, beforeDOM });
  native('type', pid, id, suffix);
  expected[name] += suffix;
  counts[name] += 1;
  await eventually(`Typed token did not reach original ${name}`, () => values(name), value => value.target === expected[name]);
}
async function checkpoint(label, baseline, names = ['A', 'B']) {
  const state = snapshot();
  unchanged(state, baseline);
  const dom = await validateValues(names);
  report.checkpoints.push({ label, at: new Date().toISOString(), native: state, dom });
  report.cases[label] = 'PASS';
  console.log(`PASS: ${label}`);
  await writeFile(join(directory, 'report.json'), JSON.stringify(report, null, 2));
}

try {
  const endpoint = await eventually('Disposable Chrome did not expose DevTools', async () => {
    if (childError) throw childError;
    if (child.exitCode !== null) throw new Error(`Disposable Chrome exited ${child.exitCode}`);
    try { return await readFile(join(directory, 'profile', 'DevToolsActivePort'), 'utf8'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; return ''; }
  }, value => value.split('\n').length >= 2, 15_000);
  const [port, path] = endpoint.trim().split('\n');
  assert(/^\d+$/.test(port) && path.startsWith('/devtools/browser/'), 'Invalid disposable DevTools endpoint');
  const listener = spawnSync('/usr/sbin/lsof', ['-nP', '-a', '-p', String(child.pid),
    `-iTCP:${port}`, '-sTCP:LISTEN', '-Fn'], { encoding: 'utf8', timeout: 5_000 });
  if (listener.error) throw listener.error;
  assert.equal(listener.status, 0, 'Cannot verify the disposable Chrome debugger listener');
  const addresses = listener.stdout.split('\n').filter(line => line.startsWith('n')).map(line => line.slice(1));
  assert.deepEqual(addresses, [`127.0.0.1:${port}`], 'Chrome debugger must listen only on IPv4 loopback');
  report.debugger = { addresses, childPID: child.pid, profile: join(directory, 'profile') };
  await cdp.connect(`ws://127.0.0.1:${port}${path}`);
  const version = await cdp.send('Browser.getVersion');
  report.chrome = version;
  const { processInfo } = await cdp.send('SystemInfo.getProcessInfo');
  pid = processInfo.find(item => item.type === 'browser')?.id;
  assert.equal(pid, child.pid, 'DevTools must belong to the exact process spawned with the disposable profile');
  browserIdentityVerified = true;
  report.chromePID = pid;
  const initial = await cdp.send('Target.getTargets');
  await createTarget('A', { left: 72, top: 100, width: 620, height: 470 });
  await createTarget('B', { left: 360, top: 230, width: 650, height: 490 });
  for (const target of initial.targetInfos.filter(item => item.type === 'page')) {
    await cdp.send('Target.closeTarget', { targetId: target.targetId });
  }
  const pair = await eventually('Expected exactly two original native Chrome windows', async () => snapshot(),
    state => state.windows.length === 2 && ['A', 'B'].every(name => state.windows.some(item => item.title.startsWith(`InfiniteDesk Desktop Fixture ${name}`))));
  const a = pair.windows.find(item => item.title.startsWith('InfiniteDesk Desktop Fixture A'));
  const b = pair.windows.find(item => item.title.startsWith('InfiniteDesk Desktop Fixture B'));
  assert.notEqual(a.id, b.id);
  assert(!sameFrame(a.frame, b.frame), 'The test requires distinct noncentral native frames');
  const baseline = [a, b];
  report.originals = { A: a, B: b };
  for (const [name, window] of [['A', a], ['B', b]]) {
    native('focus', pid, window.id);
    await evaluate(targets[name], `(() => { const field = document.querySelector('#target'); field.focus();
      field.setSelectionRange(field.value.length, field.value.length); })()`);
    await typeToken(name, window.id, `-original-${name}`);
    native('shortcut', pid, window.id, 'register');
    // The production registration has no external completion API. Subsequent
    // focus/DOM assertions fail if the hotkey was not actually registered.
    await pause(500);
  }
  report.registrationShortcutsSent = 2;
  await checkpoint('Original A/B setup input', baseline);
  let selected = b;
  async function cycle(direction, destination, name, token, label, remaining = baseline) {
    native('shortcut', pid, selected.id, direction);
    const state = await eventually(`Expected native focus on original ${name}`, async () => snapshot(),
      value => value.frontmostPID === pid && value.focusedID === destination.id);
    unchanged(state, remaining);
    selected = destination;
    await typeToken(name, destination.id, token);
    await checkpoint(label, remaining, remaining.length === 1 ? ['A'] : ['A', 'B']);
  }
  await cycle('left', a, 'A', '-cycle-A1', 'A/B/A: first A');
  await cycle('right', b, 'B', '-cycle-B', 'A/B/A: B');
  await cycle('left', a, 'A', '-cycle-A2', 'A/B/A: final A');
  for (const target of [targets.A, targets.B]) {
    await evaluate(target, 'document.title = "InfiniteDesk Identical Title"');
  }
  await eventually('Both originals did not acquire identical AX titles', async () => snapshot(), state =>
    state.windows.length === 2 && state.windows.every(item => item.title.startsWith('InfiniteDesk Identical Title')));
  await cycle('right', b, 'B', '-same-title-B', 'Identical titles: retained B identity');
  await cycle('left', a, 'A', '-same-title-A', 'Identical titles: retained A identity');

  await cdp.send('Target.closeTarget', { targetId: targets.B.targetId });
  await eventually('Original B did not close', async () => snapshot(), state => !state.windows.some(item => item.id === b.id));
  await createTarget('replacement', { left: b.frame.x, top: b.frame.y, width: b.frame.width, height: b.frame.height });
  await evaluate(targets.replacement, 'document.title = "InfiniteDesk Identical Title"');
  const replacementState = await eventually('Replacement did not match the closed window frame and shared AX title', async () => snapshot(), state => {
    const originalA = state.windows.find(item => item.id === a.id);
    const next = state.windows.find(item => item.id !== a.id && item.id !== b.id);
    return state.windows.length === 2 && originalA && next && sameFrame(b.frame, next.frame)
      && originalA.title.startsWith('InfiniteDesk Identical Title') && originalA.title === next.title;
  });
  const replacement = replacementState.windows.find(item => item.id !== a.id);
  assert.notEqual(replacement.id, b.id, 'A reused native window ID makes this negative case inconclusive');
  assert(sameFrame(b.frame, replacement.frame), 'Replacement must reproduce the original B frame');
  assert.equal(replacementState.windows.find(item => item.id === a.id).title, replacement.title,
    'Replacement and original A must have the same AX title');
  report.replacement = replacement;
  native('focus', pid, a.id);
  selected = a;
  native('shortcut', pid, a.id, 'right');
  const refusalDeadline = Date.now() + 1_500;
  do {
    const state = snapshot();
    assert.equal(state.frontmostPID, pid, 'Closed-target request changed the foreground app');
    assert.equal(state.focusedID, a.id, 'Closed-target request focused the replacement window');
    unchanged(state, [a, replacement]);
    await pause(75);
  } while (Date.now() < refusalDeadline);
  await typeToken('A', a.id, '-closed-B-refused');
  const replacementDOM = await evaluate(targets.replacement, `({target: document.querySelector('#target').value,
    decoy: document.querySelector('#decoy').value, count: document.querySelector('#count').textContent})`);
  assert.deepEqual(replacementDOM, { target: 'TARGET-B', decoy: 'DECOY-B', count: '0' });
  report.replacementDOM = replacementDOM;
  await checkpoint('Closed B with identical-title replacement did not retarget input', [a, replacement], ['A']);
  report.status = 'PASS';
} catch (error) {
  report.status = 'FAIL';
  report.error = error.stack ?? String(error);
  process.exitCode = 1;
  console.error(report.error);
} finally {
  if (browserIdentityVerified) {
    try { await cdp.send('Browser.close'); } catch { /* Closing the owned connection can precede its reply. */ }
  }
  cdp.disconnect();
  if (child.exitCode === null && !childError) {
    await Promise.race([new Promise(resolve => child.once('exit', resolve)), pause(3_000)]);
    if (child.exitCode === null) {
      child.kill('SIGTERM');
      await Promise.race([new Promise(resolve => child.once('exit', resolve)), pause(3_000)]);
    }
  }
  report.finished = new Date().toISOString();
  report.chromeExited = child.exitCode !== null || child.signalCode !== null;
  if (!report.chromeExited) { report.status = 'FAIL'; report.cleanupError = 'Owned Chrome did not exit'; process.exitCode = 1; }
  await writeFile(join(directory, 'report.json'), JSON.stringify(report, null, 2));
  console.log(`${report.status}: ${join(directory, 'report.json')}`);
}
