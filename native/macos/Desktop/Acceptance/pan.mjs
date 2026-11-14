import assert from 'node:assert/strict';
import { readFile, stat } from 'node:fs/promises';
import { bindOriginals, framesMatch, verifyGestureMotion } from './geometry.mjs';

export async function verifyPan(ctx) {
  const { originals, pid, snapshot, readModel, native, journalPath, statePath, session, report,
    eventually, evaluateFixture, fixtureShortcut, typeToken, saveReport } = ctx;
  const initial = await readModel();
  const ids = bindOriginals(initial, pid, originals);
  const world = { A: { ...originals.A.frame }, B: { ...originals.B.frame } };
  const manager = initial.managerPID;
  const finder = native('finder-snapshot').windows;
  const width = snapshot().displayWidth;
  const checkpoints = report.camera.checkpoints;
  report.camera.finder = finder;
  report.camera.displayWidth = width;
  const pan = (kind, deltas, intervalMS = 9) =>
    native('pan-input', pid, originals.B.id, JSON.stringify({ kind, deltas, intervalMS }));
  const { A, B } = originals;

  async function stableDOM(label) {
    let previous, stableSince;
    return eventually(label, async () => {
      const value = await evaluateFixture('B', '({ ...window.panFixture, y: scrollY })');
      assert(['wheel', 'pointer', 'y'].every(key => Number.isFinite(value[key])), 'Invalid fixture counters');
      const now = Date.now();
      if (!previous || ['wheel', 'pointer', 'y'].some(key => value[key] !== previous[key])) stableSince = now;
      previous = value;
      return { value, stable: now - stableSince >= 350 };
    }, sample => sample.stable).then(sample => sample.value);
  }

  async function checkedPanWheel(label, deltas) {
    const before = await stableDOM(label + ': Chrome did not settle before chord wheel');
    const input = pan('panWheel', deltas);
    const after = await stableDOM(label + ': Chrome did not settle after chord wheel');
    (report.camera.chordWheelChecks ??= []).push({ label, input, before, after });
    assert.deepEqual(after, before, label + ': chord wheel changed Chrome trusted input counters or scrollY');
  }

  function motionIntervals(samples) {
    const changes = [];
    for (const sample of samples) {
      assert(Number.isFinite(sample.ms) && Number.isFinite(sample.x), 'Invalid independent CG sample');
      if (!changes.length || Math.abs(sample.x - changes.at(-1).x) > 0.5) changes.push(sample);
    }
    const intervalsMS = changes.slice(1).map((sample, index) => sample.ms - changes[index].ms);
    const sorted = [...intervalsMS].sort((a, b) => a - b);
    const percentile = fraction => sorted.length ? sorted[Math.ceil(sorted.length * fraction) - 1] : null;
    return { source: 'Independent CGWindowList x changes sampled by the input driver; not physical display frames',
      changes, intervalsMS, count: intervalsMS.length, p50MS: percentile(0.5), p95MS: percentile(0.95), p99MS: percentile(0.99) };
  }

  function boundedDrag(deltas, startX) {
    let x = startX;
    for (const delta of deltas) {
      x -= delta;
      assert(x >= 20 && x <= width - 20, 'Planned pan pointer path leaves safe display coordinates');
    }
    return deltas;
  }

  async function check(label, expectedX, { paused = false, physicalOverride, parkedA = false, allowConstrainedA = false } = {}) {
    const result = await eventually(label, async () => {
      let state, actual;
      try {
        state = await readModel();
        actual = snapshot();
        assert.equal(state.managerPID, manager);
        assert.equal(state.testSession, session);
        assert.equal(state.camera.busy, false);
        assert.equal(state.camera.paused, paused);
        assert(Math.abs(state.camera.x - expectedX) <= 1, 'Camera offset mismatch');
        let constraint;
        for (const [name, original] of Object.entries(originals)) {
          const row = state.windows.find(w => w.id === ids[name]);
          const parked = name === 'A' && parkedA;
          assert(framesMatch(row.worldFrame, world[name]), 'Unexpected world frame for ' + name);
          assert.equal(row.parked, parked);
          assert.equal(actual.onscreenIDs.includes(original.id), !parked);
          if (!parked) {
            const visible = actual.windows.find(w => w.id === original.id);
            const expected = physicalOverride?.[name] ?? { ...world[name], x: world[name].x - expectedX };
            assert(visible && !visible.minimized, 'Original is not available: ' + name);
            assert(framesMatch(actual.onscreenFrames?.[original.id], visible.frame),
              'AX and independent WindowServer bounds disagree for ' + name);
            if (allowConstrainedA && name === 'A' && !framesMatch(visible.frame, expected)) {
              assert(/macOS constrained a partially visible window at the display edge/i.test(state.camera.detail ?? ''),
                'A deviated from projection without a published macOS edge constraint');
              assert(framesMatch({ ...visible.frame, x: expected.x }, expected), 'Edge constraint changed A size or vertical position');
              assert(visible.frame.x > expected.x && visible.frame.x < expected.x + expected.width,
                'Observed edge constraint is inconsistent with a partially visible A');
              constraint = { requested: expected, observedAX: visible.frame,
                observedCG: actual.onscreenFrames[original.id], detail: state.camera.detail };
            } else assert(framesMatch(visible.frame, expected), 'Unexpected physical frame for ' + name);
          }
        }
        const current = native('finder-snapshot').windows;
        for (const f of finder) assert(framesMatch(current.find(w => w.pid === f.pid && w.id === f.id)?.frame, f.frame));
        return { label, state, actual, ...(constraint ? { constraint } : {}), ok: true };
      } catch (e) { return { reason: e.message, camera: state?.camera, windows: state?.windows, actual }; }
    }, o => o.ok, 8000);
    checkpoints.push(result);
    console.log('PASS: ' + label);
    await saveReport();
    return result;
  }

  report.camera.status = 'RUNNING';
  await evaluateFixture('B', `(() => {
    document.body.style.minHeight = '230vh';
    window.scrollTo(0, Math.floor((document.documentElement.scrollHeight - innerHeight) / 2));
    window.panFixture = { wheel: 0, pointer: 0 };
    window.panWheelEvents = [];
    document.addEventListener('wheel', e => {
      if (e.isTrusted) {
        window.panFixture.wheel++;
        window.panWheelEvents.push({ at: performance.now(), dx: e.deltaX, dy: e.deltaY, mode: e.deltaMode,
          ctrl: e.ctrlKey, meta: e.metaKey, alt: e.altKey, y: scrollY });
      }
    }, {passive:true});
    document.addEventListener('mousedown', e => { if (e.isTrusted) window.panFixture.pointer++; });
  })()`);
  await check('Both registered originals start at the zero camera origin', 0);
  const scroll = await stableDOM('Chrome did not settle before pan drag');
  const path = boundedDrag([...Array(110).fill(-2), ...Array(70).fill(2)], B.frame.x + B.frame.width / 2);
  const sweep = pan('drag', path);
  let observation = await check('Pan moves both original windows and handles immediate reversal', -80);
  const locations = sweep.samples.map(s => s.x);
  assert(new Set(locations).size >= 3, 'Independent WindowServer samples did not show intermediate positions');
  report.camera.motion = sweep;
  report.camera.motion.observedCGIntervals = motionIntervals(sweep.samples);
  const dragDOM = await stableDOM('Chrome scroll did not settle after pan drag');
  assert.deepEqual(dragDOM, scroll, 'Unexpected Chrome input during camera drag: '
    + JSON.stringify(await evaluateFixture('B', 'window.panWheelEvents')));
  const history = await stat(journalPath, { bigint: true });
  const again = boundedDrag(Array.from({length: 180}, (_, i) => i < 90 ? -2 : 2),
    observation.actual.windows.find(w => w.id === B.id).frame.x + B.frame.width / 2);
  const reverse = pan('drag', again);
  report.camera.reversibleMotion = { ...reverse, observedCGIntervals: motionIntervals(reverse.samples) };
  observation = await check('Returning to the same camera origin keeps both world frames', -80);
  const after = await stat(journalPath, { bigint: true });
  assert.equal(after.ino, history.ino, 'The manager rewrote an existing recovery journal during ordinary pan updates');
  assert.equal(after.mtimeNs, history.mtimeNs);
  // Device settings can transform wheel deltas before they reach the session tap.
  await checkedPanWheel('Dedicated wheel moves the camera and leaves Chrome input alone', [12]);
  const wheelState = await eventually('Dedicated wheel did not move the camera', readModel,
    state => !state.camera.busy && Math.abs(state.camera.x + 80) > 1);
  await check('Dedicated wheel moves both originals by the delivered distance', wheelState.camera.x);
  const dragTo = (from, to) => {
    const distance = to - from;
    assert(Number.isInteger(distance), 'Expected integer displacement from the fixture wheel');
    const count = Math.max(1, Math.ceil(Math.abs(distance) / 16));
    const deltas = Array.from({length:count}, (_, i) =>
      Math.round(distance * (i + 1) / count) - Math.round(distance * i / count));
    return pan('drag', deltas);
  };
  const partialX = world.A.x + 32;
  dragTo(wheelState.camera.x, partialX);
  const partial = await check('Partially offscreen A preserves its world frame and exposes any macOS clamp',
    partialX, { allowConstrainedA: true });
  const partialAX = partial.actual.windows.find(w => w.id === A.id).frame;
  partial.partialProjection = { expectedX: -32, observedAX: partialAX,
    observedCG: partial.actual.onscreenFrames[A.id],
    world: partial.state.windows.find(w => w.id === ids.A).worldFrame };
  dragTo(partialX, -80);
  observation = await check('Reversing the partial-edge pan restores both original projections', -80);
  assert(await typeToken('Native input after continuous pan', 'B', B.id, '-panned'));
  const actualB = observation.actual.windows.find(w => w.id === B.id).frame;
  native('gesture', pid, B.id, JSON.stringify({kind:'drag', dx:44, dy:28, durationMS:250, expectedFrame:actualB}));
  const shifted = await eventually('Manual drag at an offset camera origin did not move B', async () => snapshot(),
    s => s.windows.some(w => w.id === B.id && w.frame.x > actualB.x && w.frame.y > actualB.y));
  const manualB = shifted.windows.find(w => w.id === B.id).frame;
  verifyGestureMotion('drag', actualB, manualB, 44, 28);
  world.B = { ...manualB, x: manualB.x - 80 };
  await check('Manual B placement updates its world frame at the current offset', -80);
  // Keep B on screen while A crosses the edge into (and back out of) parking.
  const boundary = Math.ceil(A.frame.x + A.frame.width + 24);
  dragTo(-80, boundary);
  await check('Continuous pan parks A after its entire frame leaves the screen', boundary, {parkedA:true});
  dragTo(boundary, -80);
  await check('Continuous pan restores the same A when it enters the viewport', -80);
  await eventually('Returning A displaced the active original B', async () => snapshot(),
    actual => actual.frontmostPID === pid && actual.focusedID === B.id);
  assert(await typeToken('Input stays in B after A returns', 'B', B.id, '-after-return'));
  await evaluateFixture('B', 'window.scrollTo(0, (document.documentElement.scrollHeight - innerHeight) / 2)');
  const beforeOrdinaryWheel = await stableDOM('Fixture scroll did not settle before ordinary wheel');
  pan('wheel', [12]);
  await eventually('Ordinary wheel did not reach and scroll Chrome', () => evaluateFixture('B',
    '({ ...window.panFixture, y: scrollY })'), v => v.wheel > beforeOrdinaryWheel.wheel && v.y !== beforeOrdinaryWheel.y);
  report.camera.ordinaryWheel = { before: beforeOrdinaryWheel, after: await stableDOM('Chrome scroll did not settle') };
  await check('Ordinary wheel scrolls the browser at a fixed camera offset', -80);
  await fixtureShortcut(B.id, 'togglePause');
  const paused = await readModel();
  const settled = await eventually('Pause did not finish restoring both originals', readModel,
    s => s.camera.paused && !s.camera.busy);
  const result = await check('Pause releases the original positions and honors the manual B placement',
    settled.camera.x, {paused:true, physicalOverride:{A:A.frame, B:manualB}});
  const journal = JSON.parse(await readFile(journalPath,'utf8'));
  assert.deepEqual(journal.entries, []);
  report.camera.metrics = result.state.pan ?? paused.pan;
  assert(report.camera.metrics?.continuousWorker.count > 0, 'Missing successful native pan timing');
  native('manager-quit', manager, session, statePath, journalPath);
  await eventually('Test manager did not exit', async () => {
    try { process.kill(manager, 0); return false; } catch (error) { if (error.code !== 'ESRCH') throw error; return true; }
  }, Boolean);
}
