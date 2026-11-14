import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { access, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { bindOriginals, insideWorkArea, planOriginals, planRapidDrags, PostReleaseGeometryGuard, validateState, verifyDestroyed, verifyGestureMotion, verifyModel } from './geometry.mjs';

const driver = process.argv[2];
if (!driver || typeof WebSocket === 'undefined') {
  throw new Error('Pass the compiled driver and use Node.js 22 or later');
}
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const here = dirname(fileURLToPath(import.meta.url));
const statePath = process.env.INFINITEDESK_TEST_STATE_PATH;
if (statePath !== undefined) assert(isAbsolute(statePath), 'INFINITEDESK_TEST_STATE_PATH must be an explicit absolute path');
const geometryCases = ['Original model geometry', 'External titlebar click focuses B', 'Fast titlebar drag B',
  'Real corner resize B', 'Second titlebar drag B', 'Rapid consecutive titlebar drags B', 'Chrome minimum-size constraint', 'Destroyed B model state',
  'Replacement is not automatically registered'];
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const caseNames = [
  'Original A/B setup input', 'A/B/A: first A', 'A/B/A: B', 'A/B/A: final A',
  'Identical titles: retained B identity', 'Identical titles: retained A identity',
  'Closed B with identical-title replacement did not retarget input',
];
function native(...args) {
  const result = spawnSync(driver, args.map(String), { encoding: 'utf8', timeout: 15_000 });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    let payload;
    try { payload = JSON.parse(result.stdout); } catch { /* Transport failures have stderr only. */ }
    const error = new Error(payload?.reason ?? (result.stdout.trim() || result.stderr.trim()));
    if (payload) error.driverResult = payload;
    throw error;
  }
  return JSON.parse(result.stdout);
}
const check = spawnSync(driver, ['preflight'], { encoding: 'utf8', timeout: 15_000 });
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
    geometry: { status: statePath ? 'SKIP' : 'NOT_REQUESTED', cases: Object.fromEntries(geometryCases.map(name => [name, 'NOT_RUN'])) },
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
  schemaVersion: 2,
  status: 'RUNNING', started: new Date().toISOString(),
  platform: process.platform, architecture: process.arch, node: process.version,
  directory, prerequisites: JSON.parse(check.stdout),
  scope: 'Real desktop manager keyboard shortcuts; disposable Chrome only',
  checkpoints: [],
  inputEvidence: [],
  inputCases: {},
  nativeFocusCases: Object.fromEntries(caseNames.slice(1).map(name => [name, 'NOT_RUN'])),
  nativeFocusStatus: 'NOT_RUN',
  inputStatus: 'NOT_RUN',
  geometry: { status: statePath ? 'NOT_RUN' : 'NOT_REQUESTED', statePath: statePath ?? null,
    cases: Object.fromEntries(geometryCases.map(name => [name, 'NOT_RUN'])), evidence: [],
    finder: { status: 'NOT_RUN' }, constraint: { status: 'NOT_RUN' } },
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
let geometryContext;

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
  assert(snapshot && Array.isArray(snapshot.windows), 'Native snapshot is unavailable or invalid');
  for (const window of baseline) {
    const current = snapshot.windows.find(item => item.id === window.id);
    assert(current, `Registered CG window ${window.id} is missing`);
    assert(sameFrame(current.frame, window.frame), `Native frame changed for ${window.id}: ${JSON.stringify(current.frame)}`);
  }
}
function requireNative(observed) {
  if (observed.nativeError) throw new Error(`Native observation failed: ${observed.nativeError}`);
  assert(observed.native, 'Native observation did not return a snapshot');
  return observed.native;
}
async function values(name) {
  return evaluate(targets[name], `({target: document.querySelector('#target').value,
    decoy: document.querySelector('#decoy').value, output: document.querySelector('#value').textContent,
    count: Number(document.querySelector('#count').textContent), focused: document.hasFocus(),
    active: document.activeElement?.id, title: document.title, visibility: document.visibilityState,
    selection: {start: document.querySelector('#target').selectionStart,
      end: document.querySelector('#target').selectionEnd, direction: document.querySelector('#target').selectionDirection},
    events: (window.fixtureEvents ?? []).slice(-40)})`);
}
async function evidence() {
  const result = { at: new Date().toISOString(), dom: {} };
  try { result.native = snapshot(); } catch (error) { result.nativeError = String(error); }
  for (const name of Object.keys(targets)) {
    try { result.dom[name] = await values(name); }
    catch (error) { result.dom[name] = { error: String(error) }; }
  }
  if (statePath) {
    try { result.model = await readModel(); } catch (error) { result.modelError = String(error); }
  }
  return result;
}
async function readModel() {
  assert(statePath, 'Geometry cases require INFINITEDESK_TEST_STATE_PATH');
  return validateState(JSON.parse(await readFile(statePath, 'utf8')));
}
async function fixtureShortcut(windowID, command) {
  if (statePath) {
    const state = await readModel();
    assert(state.windows.every(window => window.pid === pid), 'Refusing shortcuts while unrelated windows are registered');
  }
  return native('shortcut', pid, windowID, command);
}
async function saveReport() {
  await writeFile(join(directory, 'report.json'), JSON.stringify(report, null, 2));
}
async function typeToken(label, name, id, suffix) {
  const attempt = { label, name, id, token: suffix, status: 'RUNNING', before: await evidence() };
  report.inputEvidence.push(attempt);
  try {
    const beforeNative = requireNative(attempt.before);
    assert.equal(beforeNative?.frontmostPID, pid, 'Typing must not activate the application');
    assert.equal(beforeNative?.focusedID, id, 'Typing must not select the destination window');
    const beforeDOM = attempt.before.dom[name];
    assert.equal(beforeDOM.focused, true, `Original ${name} did not have native page focus before typing`);
    assert.equal(beforeDOM.active, 'target', `Original ${name} target was not already the active field`);
    assert.equal(beforeDOM.selection.start, beforeDOM.target.length, 'Native typing probe requires an existing caret at the end');
    assert.equal(beforeDOM.selection.end, beforeDOM.target.length, 'Native typing probe requires no selection');
    attempt.expected = beforeDOM.target + suffix;
    attempt.driverResult = native('type', pid, id, suffix);
    await eventually(`Typed token did not reach original ${name}`, async () => {
      const value = await values(name);
      const { events, ...summary } = value;
      return summary;
    }, value => value.target === attempt.expected);
  } catch (error) {
    attempt.error = error.stack ?? String(error);
    if (error.driverResult) attempt.driverFailure = error.driverResult;
  }
  attempt.after = await evidence();
  try {
    if (attempt.error) throw new Error(attempt.error);
    const before = attempt.before.dom[name];
    const after = attempt.after.dom[name];
    assert.equal(after.target, attempt.expected);
    assert.equal(after.output, attempt.expected, 'The page did not process the native input event');
    assert(after.count > before.count, 'No DOM input event was observed');
    for (const [otherName, previous] of Object.entries(attempt.before.dom)) {
      const current = attempt.after.dom[otherName];
      if (previous.error || current?.error) continue;
      assert.equal(current.decoy, previous.decoy, `${otherName} decoy changed`);
      if (otherName !== name) {
        for (const field of ['target', 'output', 'count']) {
          assert.equal(current[field], previous[field], `Input leaked into ${otherName} ${field}`);
        }
      }
    }
    attempt.status = 'PASS';
  } catch (error) {
    attempt.status = 'FAIL';
    attempt.error ??= error.stack ?? String(error);
  }
  report.inputCases[label] = attempt.status;
  report.inputStatus = Object.values(report.inputCases).includes('FAIL') ? 'FAIL' : 'INCOMPLETE';
  console.log(`${attempt.status}: native input ${label}`);
  if (attempt.status === 'FAIL') {
    const dom = Object.fromEntries(Object.entries(attempt.after.dom).map(([page, value]) => {
      const { events, ...summary } = value;
      return [page, summary];
    }));
    console.error(JSON.stringify({ label, error: attempt.error.split('\n')[0], native: attempt.after.native, dom }));
  }
  await saveReport();
  return attempt.status === 'PASS';
}
async function nativeCheckpoint(label, baseline, expectedID) {
  const state = snapshot();
  unchanged(state, baseline);
  assert.equal(state.frontmostPID, pid);
  assert.equal(state.focusedID, expectedID);
  const observed = await evidence();
  report.checkpoints.push({ label, scope: 'native focus and unchanged frames; input assessed separately',
    native: state, observed });
  report.nativeFocusCases[label] = 'PASS';
  console.log(`PASS: native focus ${label}`);
  await saveReport();
}

function finderUnchanged(current) {
  for (const window of geometryContext.finder) {
    const actual = current.windows.find(item => item.pid === window.pid && item.id === window.id);
    if (!actual || !sameFrame(actual.frame, window.frame)) {
      report.geometry.finder.status = 'FAIL';
      throw new Error(`Existing Finder CG window ${window.id} changed or disappeared`);
    }
  }
}
async function settleGeometry(focusedName, samples, allowFocusTransition, released) {
  const deadline = Date.now() + 10_000;
  let stableSince = Date.now();
  let previous;
  const releaseGuard = new PostReleaseGeometryGuard(released.frame, released.observedAt, released.releasedAt);
  do {
    const actual = snapshot();
    const sample = { at: new Date().toISOString(), native: actual };
    samples.push(sample);
    const originals = geometryContext.originals;
    unchanged(actual, [originals.A]);
    assert.equal(actual.frontmostPID, pid, 'Gesture changed the foreground application');
    assert.equal(actual.focusedID, originals[focusedName].id, 'Gesture lost the expected native window focus');
    const b = actual.windows.find(window => window.id === originals.B.id);
    assert(b, 'Gesture lost original B CG identity');
    const finder = native('finder-snapshot');
    sample.finder = finder;
    finderUnchanged(finder);
    sample.releaseAnchor = releaseGuard.observe(b.frame, Date.now());
    try { sample.model = await readModel(); }
    catch (error) { sample.modelError = String(error); }
    if (sample.model) {
      bindOriginals(sample.model, pid, originals, geometryContext.binding);
      if (!allowFocusTransition) {
        assert.equal(sample.model.focusedID, geometryContext.binding[focusedName], 'A move/resize changed the already confirmed model focusedID');
      }
      try { verifyModel(sample.model, pid, originals, geometryContext.binding, actual, focusedName); }
      catch (error) { sample.modelError = String(error); }
    }
    if (!previous || !sameFrame(previous, b.frame)) stableSince = Date.now();
    previous = b.frame;
    if (!sample.modelError && samples.length >= 3 && Date.now() - stableSince >= 1_000
      && sample.releaseAnchor && Date.now() - sample.releaseAnchor.at >= 750) {
      return { samples, final: sample, b };
    }
    await pause(75);
  } while (Date.now() < deadline);
  throw new Error(`Native/model geometry did not settle: ${JSON.stringify(samples.at(-1))}`);
}
async function geometryGesture(label, kind, dx, dy, durationMS, constraint = false, segments) {
  report.geometry.cases[label] = 'RUNNING';
  const record = { label, kind, dx, dy, before: await evidence() };
  report.geometry.evidence.push(record);
  try {
    const before = requireNative(record.before);
    const window = before.windows.find(item => item.id === geometryContext.originals.B.id);
    assert(window, 'Original B is missing before gesture');
    unchanged(before, [geometryContext.originals.A]);
    record.requestedFrame = kind === 'resize'
      ? { ...window.frame, width: window.frame.width + dx, height: window.frame.height + dy }
      : { ...window.frame, x: window.frame.x + dx, y: window.frame.y + dy };
    if (kind === 'click') record.requestedFrame = { ...window.frame };
    assert(insideWorkArea(record.requestedFrame, report.geometry.workArea, 16), 'Requested gesture frame must remain inside the work area');
    record.drivers = [];
    record.segmentEvidence = [];
    let expectedFrame = { ...window.frame };
    for (const segment of segments ?? [{ dx, dy, durationMS }]) {
      const requested = kind === 'resize'
        ? { ...expectedFrame, width: expectedFrame.width + segment.dx, height: expectedFrame.height + segment.dy }
        : { ...expectedFrame, x: expectedFrame.x + segment.dx, y: expectedFrame.y + segment.dy };
      assert(insideWorkArea(requested, report.geometry.workArea, 16), 'Intermediate mouse path must keep the whole window in the work area');
      const receipt = native('gesture', pid, window.id, JSON.stringify({ kind, ...segment, expectedFrame }));
      record.drivers.push(receipt);
      const actual = snapshot();
      unchanged(actual, [geometryContext.originals.A]);
      assert.equal(actual.frontmostPID, pid);
      assert.equal(actual.focusedID, window.id);
      const moved = actual.windows.find(item => item.id === window.id);
      assert(moved, 'Real gesture lost the original native window');
      record.segmentEvidence.push({ beforeFrame: expectedFrame, requestedFrame: requested, nativeAfter: actual,
        at: new Date().toISOString(), driver: receipt });
      assert(insideWorkArea(moved.frame, report.geometry.workArea, 16), 'Actual gesture frame left the work area');
      verifyGestureMotion(kind, expectedFrame, moved.frame, segment.dx, segment.dy, constraint);
      expectedFrame = { ...moved.frame };
    }
    record.settling = [];
    const finalSegment = record.segmentEvidence.at(-1);
    record.releaseObservation = { frame: expectedFrame, observedAt: Date.parse(finalSegment.at),
      releasedAt: record.drivers.at(-1).completedAt * 1000 };
    const settled = await settleGeometry('B', record.settling, kind === 'click', record.releaseObservation);
    record.actualFrame = settled.b.frame;
    geometryContext.latestB = settled.b;
    verifyGestureMotion(kind, window.frame, record.actualFrame, dx, dy, constraint);
    const after = await evidence();
    record.after = after;
    for (const name of ['A', 'B']) {
      for (const field of ['target', 'decoy', 'output', 'count']) {
        assert.equal(after.dom[name]?.[field], record.before.dom[name]?.[field], `Gesture edited ${name} ${field}`);
      }
    }
    if (constraint) {
      const changed = !sameFrame(window.frame, record.actualFrame);
      const constrained = record.actualFrame.width > record.requestedFrame.width + 2 || record.actualFrame.height > record.requestedFrame.height + 2;
      record.status = changed && constrained ? 'PASS' : changed ? 'NOT_OBSERVED' : 'INCONCLUSIVE';
      report.geometry.constraint = { status: record.status, requestedFrame: record.requestedFrame, actualFrame: record.actualFrame,
        reason: changed && constrained ? 'Chrome resized but applied its own minimum dimensions; model matched actual AX geometry'
          : 'A minimum-size constraint was not established by this real-corner gesture' };
    } else record.status = 'PASS';
    report.geometry.cases[label] = record.status;
    console.log(`${record.status}: geometry ${label}`);
    await saveReport();
  } catch (error) {
    record.status = 'FAIL';
    record.error = error.stack ?? String(error);
    if (error.driverResult) record.driverFailure = error.driverResult;
    report.geometry.cases[label] = 'FAIL';
    report.geometry.status = 'FAIL';
    throw error;
  }
}
async function stageTwo(originals) {
  report.geometry.status = 'RUNNING';
  report.geometry.zOrderSetup = { before: await evidence() };
  native('focus', pid, originals.B.id);
  native('focus', pid, originals.A.id);
  report.geometry.zOrderSetup.after = await evidence();
  const state = await eventually('Model did not register both original frames', async () => {
    try {
      const model = await readModel();
      const binding = bindOriginals(model, pid, originals);
      verifyModel(model, pid, originals, binding, snapshot(), 'A');
      return { model, binding };
    } catch (error) { return { error: String(error) }; }
  }, value => Boolean(value.binding));
  const finder = native('finder-snapshot');
  geometryContext = { originals, binding: state.binding, finder: finder.windows, latestB: originals.B };
  report.geometry.binding = state.binding;
  report.geometry.initialModel = state.model;
  report.geometry.finder = { status: finder.windows.length ? 'RUNNING' : 'SKIP', baseline: finder.windows,
    reason: finder.windows.length ? 'Existing Finder window IDs and frames are checked after every gesture' : 'No visible ordinary Finder window existed; Finder was not opened' };
  report.geometry.cases['Original model geometry'] = 'PASS';
  const area = report.geometry.workArea;
  assert(insideWorkArea(originals.A.frame, area, 16) && insideWorkArea(originals.B.frame, area, 16), 'Original native frames must fit the work area');
  assert(originals.A.frame.y + originals.A.frame.height < originals.B.frame.y, 'A must not obscure the initial B titlebar');
  const midpoint = area.x + area.width / 2;
  assert(originals.B.frame.x + originals.B.frame.width / 2 < midpoint, 'B must start in the left half');
  await geometryGesture('External titlebar click focuses B', 'click', 0, 0, 150);
  const crossDX = Math.ceil(midpoint) + 24 - geometryContext.latestB.frame.x;
  assert(Math.abs(crossDX) <= 1000, 'Cross-half drag exceeds the guarded input range');
  await geometryGesture('Fast titlebar drag B', 'drag', crossDX, 0, 140);
  assert(geometryContext.latestB.frame.x > midpoint, 'B must reach the right half after the fast drag');
  const moved = geometryContext.latestB.frame;
  const resizeDX = Math.min(80, Math.floor(area.x + area.width - moved.x - moved.width - 24));
  const resizeDY = Math.min(55, Math.floor(area.y + area.height - moved.y - moved.height - 24));
  assert(resizeDX >= 10 && resizeDY >= 10, 'The work area has insufficient room for the real resize');
  await geometryGesture('Real corner resize B', 'resize', resizeDX, resizeDY, 300);
  await geometryGesture('Second titlebar drag B', 'drag', -24, -18, 220);
  const rapid = planRapidDrags(geometryContext.latestB.frame, originals.A.frame, area);
  await geometryGesture('Rapid consecutive titlebar drags B', 'drag',
    rapid.reduce((sum, segment) => sum + segment.dx, 0), rapid.reduce((sum, segment) => sum + segment.dy, 0),
    150, false, rapid);
  const current = geometryContext.latestB.frame;
  await geometryGesture('Chrome minimum-size constraint', 'resize', 160 - current.width, 120 - current.height, 450, true);
  if (geometryContext.finder.length) report.geometry.finder.status = 'PASS';
  await saveReport();
}

try {
  if (statePath) {
    const initial = await readModel();
    report.geometry.initialEmptyModel = initial;
    assert.equal(initial.windows.length, 0, 'Stage 2 requires an actually empty manager model before any shortcuts');
  }
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
  if (statePath) {
    const first = initial.targetInfos.find(target => target.type === 'page');
    assert(first, 'Expected an owned blank page for work-area discovery');
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId: first.targetId, flatten: true });
    const area = await evaluate({ sessionId }, '({x: screen.availLeft, y: screen.availTop, width: screen.availWidth, height: screen.availHeight})');
    report.geometry.workArea = area;
    const plan = planOriginals(area);
    report.geometry.plannedOriginals = plan;
    for (const name of ['A', 'B']) {
      const frame = plan[name];
      await createTarget(name, { left: frame.x, top: frame.y, width: frame.width, height: frame.height });
    }
  } else {
    await createTarget('A', { left: 72, top: 100, width: 620, height: 470 });
    await createTarget('B', { left: 360, top: 230, width: 650, height: 490 });
  }
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
  let setupInputPassed = true;
  for (const [name, window] of [['A', a], ['B', b]]) {
    native('focus', pid, window.id);
    await evaluate(targets[name], `(() => { const field = document.querySelector('#target'); field.focus();
      field.setSelectionRange(field.value.length, field.value.length); })()`);
    const inputPassed = await typeToken(`Setup ${name}`, name, window.id, `-original-${name}`);
    setupInputPassed = inputPassed && setupInputPassed;
    if (statePath && name === 'A') {
      assert.equal((await readModel()).windows.length, 0, 'Manager gained registrations during setup; refusing the first shortcut');
    }
    await fixtureShortcut(window.id, 'register');
    // The production registration has no external completion API. Subsequent
    // focus/DOM assertions fail if the hotkey was not actually registered.
    await pause(500);
  }
  report.registrationShortcutsSent = 2;
  report.cases['Original A/B setup input'] = setupInputPassed ? 'PASS' : 'FAIL';
  report.setupEvidence = await evidence();
  unchanged(requireNative(report.setupEvidence), baseline);
  await saveReport();
  let selected = b;
  async function cycle(direction, destination, name, token, label, remaining = baseline) {
    report.activeNativeCase = label;
    await fixtureShortcut(selected.id, direction);
    const state = await eventually(`Expected native focus on original ${name}`, async () => snapshot(),
      value => value.frontmostPID === pid && value.focusedID === destination.id);
    unchanged(state, remaining);
    selected = destination;
    await nativeCheckpoint(label, remaining, destination.id);
    const inputPassed = await typeToken(label, name, destination.id, token);
    report.cases[label] = inputPassed ? 'PASS' : 'FAIL';
    await saveReport();
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

  if (statePath) await stageTwo({ A: a, B: b });
  const closedBFrame = geometryContext?.latestB.frame ?? b.frame;

  await cdp.send('Target.closeTarget', { targetId: targets.B.targetId });
  await eventually('Original B did not close', async () => snapshot(), state => !state.windows.some(item => item.id === b.id));
  if (geometryContext) {
    const model = await eventually('Destroyed B remained available in the model', async () => {
      try { const state = await readModel(); verifyDestroyed(state, pid, geometryContext.binding); return { state }; }
      catch (error) { return { error: String(error) }; }
    }, value => Boolean(value.state));
    report.geometry.destroyedModel = model.state;
    report.geometry.cases['Destroyed B model state'] = 'PASS';
  }
  await createTarget('replacement', { left: closedBFrame.x, top: closedBFrame.y, width: closedBFrame.width, height: closedBFrame.height });
  await evaluate(targets.replacement, 'document.title = "InfiniteDesk Identical Title"');
  const replacementState = await eventually('Replacement did not match the closed window frame and shared AX title', async () => snapshot(), state => {
    const originalA = state.windows.find(item => item.id === a.id);
    const next = state.windows.find(item => item.id !== a.id && item.id !== b.id);
    return state.windows.length === 2 && originalA && next && sameFrame(closedBFrame, next.frame)
      && originalA.title.startsWith('InfiniteDesk Identical Title') && originalA.title === next.title;
  });
  const replacement = replacementState.windows.find(item => item.id !== a.id);
  assert.notEqual(replacement.id, b.id, 'A reused native window ID makes this negative case inconclusive');
  assert(sameFrame(closedBFrame, replacement.frame), 'Replacement must reproduce the closed B frame');
  assert.equal(replacementState.windows.find(item => item.id === a.id).title, replacement.title,
    'Replacement and original A must have the same AX title');
  report.replacement = replacement;
  native('focus', pid, a.id);
  if (geometryContext) {
    const model = await eventually('Unregistered replacement changed model registration/focus', async () => {
      try { const state = await readModel(); verifyDestroyed(state, pid, geometryContext.binding); return { state }; }
      catch (error) { return { error: String(error) }; }
    }, value => Boolean(value.state));
    report.geometry.replacementModel = model.state;
    report.geometry.cases['Replacement is not automatically registered'] = 'PASS';
  }
  selected = a;
  report.activeNativeCase = 'Closed B with identical-title replacement did not retarget input';
  await fixtureShortcut(a.id, 'right');
  const refusalDeadline = Date.now() + 1_500;
  do {
    const state = snapshot();
    assert.equal(state.frontmostPID, pid, 'Closed-target request changed the foreground app');
    assert.equal(state.focusedID, a.id, 'Closed-target request focused the replacement window');
    unchanged(state, [a, replacement]);
    await pause(75);
  } while (Date.now() < refusalDeadline);
  await nativeCheckpoint('Closed B with identical-title replacement did not retarget input', [a, replacement], a.id);
  const closedInputPassed = await typeToken('Closed B with identical-title replacement did not retarget input', 'A', a.id, '-closed-B-refused');
  const replacementDOM = await evaluate(targets.replacement, `({target: document.querySelector('#target').value,
    decoy: document.querySelector('#decoy').value, count: document.querySelector('#count').textContent})`);
  report.replacementDOM = replacementDOM;
  const replacementUntouched = replacementDOM.target === 'TARGET-B' && replacementDOM.decoy === 'DECOY-B' && replacementDOM.count === '0';
  report.cases['Closed B with identical-title replacement did not retarget input'] = closedInputPassed && replacementUntouched ? 'PASS' : 'FAIL';
  if (!replacementUntouched) {
    report.replacementInputFailure = 'The unregistered replacement was edited; native focus result is separate';
  }
  unchanged(snapshot(), [a, replacement]);
  if (geometryContext) {
    finderUnchanged(native('finder-snapshot'));
    verifyDestroyed(await readModel(), pid, geometryContext.binding);
    report.geometry.status = 'PASS';
  }
  report.nativeFocusStatus = 'PASS';
  report.inputStatus = Object.values(report.inputCases).every(value => value === 'PASS') && replacementUntouched ? 'PASS' : 'FAIL';
  report.status = report.inputStatus;
  if (report.status === 'FAIL') process.exitCode = 1;
} catch (error) {
  report.status = 'FAIL';
  if (statePath && report.geometry.status !== 'PASS') report.geometry.status = 'FAIL';
  report.error = error.stack ?? String(error);
  report.nativeFocusStatus = 'INCOMPLETE';
  if (report.activeNativeCase && report.nativeFocusCases[report.activeNativeCase] !== 'PASS') {
    report.nativeFocusCases[report.activeNativeCase] = 'FAIL';
  }
  report.failureEvidence = browserIdentityVerified ? await evidence() : { reason: 'Disposable browser identity was not established' };
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
