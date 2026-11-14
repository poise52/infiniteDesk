import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { bindOriginals, framesMatch } from './geometry.mjs';

export async function verifyOverview(context) {
  const { originals, pid, readBounds, readModel, journalPath, statePath, session, snapshot, native,
    fixtureShortcut, typeToken, eventually, report, saveReport, evaluateFixture } = context;
  const initial = await readModel();
  const binding = bindOriginals(initial, pid, originals);
  const managerPID = initial.managerPID;
  const width = snapshot().displayWidth;
  const finder = native('finder-snapshot').windows;
  const overview = { status: 'RUNNING', binding, checkpoints: [], keys: [] };
  report.camera.overview = overview;
  assert(width > 0 && initial.camera.x === 0 && initial.camera.paused === false);
  native('manager-identity', managerPID, session, statePath, journalPath);
  let movedB = false;

  async function observe() {
    const dom = {};
    const bounds = {};
    for (const name of ['A', 'B']) {
      dom[name] = await evaluateFixture(name, `({target: document.querySelector('#target').value,
        decoy: document.querySelector('#decoy').value, output: document.querySelector('#value').textContent,
        count: Number(document.querySelector('#count').textContent)})`);
      bounds[name] = await readBounds(name);
    }
    return { state: await readModel(), actual: snapshot(), bounds, dom };
  }
  function unchangedWorld(state) {
    assert.equal(state.managerPID, managerPID);
    assert.equal(state.testSession, session);
    bindOriginals(state, pid, originals, binding);
    assert.equal(state.windows[0].id, binding.A, 'Original A registration order changed');
    assert.equal(state.windows[1].id, binding.B, 'Original B registration order changed');
    assert(state.windows.every(window => window.title.startsWith('InfiniteDesk Identical Title')),
      'Overview must exercise two identical-title registrations');
    for (const name of ['A', 'B']) {
      const record = state.windows.find(window => window.id === binding[name]);
      const expected = { ...originals[name].frame, x: originals[name].frame.x + (name === 'B' && movedB ? width : 0) };
      assert(framesMatch(record.worldFrame, expected), `${name} world geometry changed`);
      assert(framesMatch(record.originalFrame, originals[name].frame), `${name} original geometry changed`);
    }
  }
  function aligned(observed, focus) {
    const { state, actual, bounds } = observed;
    unchangedWorld(state);
    assert.equal(state.camera.busy, false);
    assert.equal(actual.frontmostPID, pid, 'The nonactivating overview must leave Chrome foreground');
    if (focus) {
      assert.equal(actual.focusedID, originals[focus].id, `Native focus must identify original ${focus}`);
      assert.equal(state.focusedID, binding[focus], `Model focus must identify original ${focus}`);
    }
    for (const name of ['A', 'B']) {
      const record = state.windows.find(window => window.id === binding[name]);
      const window = actual.windows.find(item => item.id === originals[name].id);
      assert(window, `Lost original ${name} native identity`);
      assert.equal(window.minimized, record.parked, `${name} AX minimization disagrees with manager ownership`);
      assert.equal(bounds[name].windowState, record.parked ? 'minimized' : 'normal', `${name} independent browser state`);
      assert.equal(actual.onscreenIDs.includes(window.id), !record.parked, `${name} independent CG visibility`);
      assert(Math.abs(window.frame.width - originals[name].frame.width) <= 1
        && Math.abs(window.frame.height - originals[name].frame.height) <= 1, `${name} must stay at native 1:1 size`);
      if (!record.parked && !state.camera.paused) {
        const physical = { ...record.worldFrame, x: record.worldFrame.x - state.camera.x,
          y: record.worldFrame.y - state.camera.y };
        assert(framesMatch(window.frame, physical), `${name} native frame must match world minus camera origin`);
      }
    }
    const currentFinder = native('finder-snapshot').windows;
    for (const window of finder) assert(framesMatch(
      currentFinder.find(item => item.pid === window.pid && item.id === window.id)?.frame, window.frame),
    'Overview changed an unregistered Finder frame');
  }
  async function checkpoint(label, validate) {
    const observed = await eventually(label, async () => {
      try {
        const result = await observe();
        validate(result);
        return { ...result, ok: true };
      } catch (error) { return { error: error.message }; }
    }, result => result.ok, 10_000);
    overview.checkpoints.push({ label, ...observed });
    console.log(`PASS: overview ${label}`);
    await saveReport();
    return observed;
  }
  async function open(focus) {
    await fixtureShortcut(originals[focus].id, 'overview');
    return checkpoint('Open exact nonactivating panel from ' + focus, observed => {
      aligned(observed, focus);
      assert.equal(observed.state.overview?.visible, true);
      assert.equal(observed.state.overview.isKey, true);
      assert(Number.isInteger(observed.state.overview.windowNumber) && observed.state.overview.windowNumber > 0);
      assert.equal(observed.state.overview.selectedID, binding[focus]);
    });
  }
  async function key(name, focus, selected) {
    const model = await readModel();
    assert.equal(model.overview?.selectedID, binding[selected]);
    const receipt = native('manager-overview-key', managerPID, session, statePath, journalPath,
      name, pid, originals[focus].id, model.overview.windowNumber, binding[selected]);
    overview.keys.push(receipt);
    await saveReport();
  }
  const before = await checkpoint('Original identical-title A/B at native 1:1', observed => {
    aligned(observed, 'B');
    assert.equal(observed.state.overview?.visible, false);
  });
  await open('B');
  await key('escape', 'B', 'B');
  await checkpoint('Escape preserves exact focus, frames, camera, and input', observed => {
    aligned(observed, 'B');
    assert.equal(observed.state.overview?.visible, false);
    assert.deepEqual(observed.state.camera, before.state.camera);
    assert.deepEqual(observed.dom, before.dom, 'Overview keys leaked into a fixture input');
    for (const name of ['A', 'B']) assert(framesMatch(
      observed.actual.windows.find(window => window.id === originals[name].id)?.frame, originals[name].frame));
  });
  await fixtureShortcut(originals.B.id, 'newPage');
  movedB = true;
  await checkpoint('Move B one page away and park exact A', observed => {
    aligned(observed, 'B');
    assert.equal(observed.state.camera.x, width);
    assert.equal(observed.state.windows.find(window => window.id === binding.A).parked, true);
  });
  for (const [from, destination, selectionKey] of [['B', 'A', 'tab'], ['A', 'B', 'backtab']]) {
    const opened = await open(from);
    await key(selectionKey, from, from);
    await checkpoint('Select original ' + destination + ' through ' + selectionKey, observed => {
      aligned(observed, from);
      assert.equal(observed.state.overview?.visible, true);
      assert.equal(observed.state.overview.selectedID, binding[destination]);
      assert.deepEqual(observed.state.camera, opened.state.camera);
      assert.deepEqual(observed.dom, opened.dom, 'Selection keys must stay in the confirmed overview');
    });
    await key('enter', from, destination);
    await checkpoint('Enter returns to exact original ' + destination + ' at native 1:1', observed => {
      aligned(observed, destination);
      assert.equal(observed.state.overview?.visible, false);
      assert.equal(observed.state.windows.find(window => window.id === binding[destination]).parked, false);
    });
    assert(await typeToken('Overview return input ' + destination, destination, originals[destination].id,
      '-overview-' + destination), 'Native token must reach the exact chosen original');
  }
  await fixtureShortcut(originals.B.id, 'togglePause');
  await checkpoint('Pause restores both original frames and clears durable ownership', observed => {
    aligned(observed, 'B');
    assert.equal(observed.state.camera.paused, true);
    for (const name of ['A', 'B']) assert(framesMatch(
      observed.actual.windows.find(window => window.id === originals[name].id)?.frame, originals[name].frame));
  });
  assert.deepEqual(JSON.parse(await readFile(journalPath, 'utf8')).entries, []);
  overview.status = 'PASS';
  await saveReport();
}
