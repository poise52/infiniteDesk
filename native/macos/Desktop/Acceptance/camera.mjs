import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { bindOriginals, framesMatch, verifyGestureMotion } from './geometry.mjs';
import { verifyCameraLifecycle } from './camera-lifecycle.mjs';

export async function verifyCamera(context) {
  const { mode, originals, pid, readBounds, readModel, journalPath, session, snapshot, native,
    fixtureShortcut, typeToken, eventually, report, saveReport } = context;
  const pageRoundTrips = Number(process.env.INFINITEDESK_TEST_PAGE_ROUNDTRIPS ?? '0');
  assert(Number.isInteger(pageRoundTrips) && pageRoundTrips >= 0 && pageRoundTrips <= 10,
    'INFINITEDESK_TEST_PAGE_ROUNDTRIPS must be an integer from 0 to 10');
  assert(mode === 'quit' || pageRoundTrips === 0, 'Additional page round trips require quit mode');
  const initial = await readModel();
  assert.equal(initial.testSession, session);
  assert.equal(initial.camera.page, 0);
  assert.equal(initial.camera.pendingRecoveryCount, 0);
  assert.equal(initial.windows.length, 2);
  const binding = bindOriginals(initial, pid, originals);
  const local = { A: originals.A.frame, B: originals.B.frame };
  const width = snapshot().displayWidth;
  const finder = native('finder-snapshot').windows;
  const pages = { A: 0, B: 1 };
  assert(width > 0);
  report.camera.status = 'RUNNING';
  report.camera.displayWidth = width;
  report.camera.finder = finder;
  report.camera.binding = binding;
  report.camera.pageRoundTrips = pageRoundTrips;
  const receipt = native('manager-identity', initial.managerPID, session, context.statePath, journalPath);
  assert.equal(receipt.pid, initial.managerPID);

  async function check(label, page, paused, focus) {
    const result = await eventually(label, async () => {
      let state, actual, bounds;
      try {
        state = await readModel();
        actual = snapshot();
        bounds = { A: await readBounds('A'), B: await readBounds('B') };
        const journal = JSON.parse(await readFile(journalPath, 'utf8'));
        assert.equal(state.testSession, session);
        assert.equal(state.managerPID, initial.managerPID);
        assert.deepEqual([state.camera.page, state.camera.paused, state.camera.busy], [page, paused, false]);
        if (!paused) assert.equal(state.camera.x, page * width);
        const parkedIDs = [];
        for (const name of ['A', 'B']) {
          const record = state.windows.find(w => w.id === binding[name]);
          const parked = !paused && pages[name] !== page;
          assert.equal(record?.page, pages[name]);
          assert.equal(record.parked, parked);
          const expected = { ...local[name], x: local[name].x + pages[name] * width };
          assert(framesMatch(record.worldFrame, expected), name + ' world frame mismatch');
          assert(framesMatch(record.originalFrame, originals[name].frame), name + ' original frame changed');
          assert.equal(actual.onscreenIDs.includes(originals[name].id), !parked, name + ' CG visibility');
          assert.equal(bounds[name].windowState, parked ? 'minimized' : 'normal', name + ' native Chrome state');
          if (parked) parkedIDs.push(binding[name]);
          else {
            const visible = actual.windows.find(w => w.id === originals[name].id);
            assert(visible && !visible.minimized && framesMatch(visible.frame, local[name]), name + ' original visible frame');
          }
        }
        assert.deepEqual(journal.entries.map(e => e.id).sort(), parkedIDs.sort());
        assert(journal.entries.every(e => e.pid === pid && e.lastIntendedMinimized === true));
        if (focus) {
          assert.equal(actual.frontmostPID, pid, 'Chrome must keep foreground');
          assert.equal(actual.focusedID, originals[focus].id, 'Native focus must reach original ' + focus);
          assert.equal(state.focusedID, binding[focus], 'Manager must observe focus on ' + focus);
        }
        const currentFinder = native('finder-snapshot').windows;
        for (const entry of finder) {
          assert(framesMatch(currentFinder.find(w => w.id === entry.id && w.pid === entry.pid)?.frame, entry.frame),
            'The camera changed an unregistered Finder window');
        }
        return { state, actual, bounds, journal, ok: true };
      } catch (error) {
        return { error: error.message, camera: state?.camera, windows: state?.windows, actual, bounds };
      }
    }, observed => observed.ok, 8500);
    report.camera.checkpoints.push({ label, ...result });
    report.camera.metrics = result.state.pan;
    console.log('PASS: ' + label);
    await saveReport();
  }

  await fixtureShortcut(originals.B.id, 'newPage');
  await check('Move B one page right and follow it', 1, false, 'B');
  assert(local.B.x + width - local.A.x > width);
  assert(await typeToken('Type directly in B on page 1', 'B', originals.B.id, '-page-B'));
  native('gesture', pid, originals.B.id, JSON.stringify({ kind: 'drag', dx: 70, dy: 40, durationMS: 240,
    expectedFrame: local.B }));
  const moved = await eventually('B did not move after its titlebar drag', async () => snapshot(), s =>
    s.windows.some(w => w.id === originals.B.id && !framesMatch(w.frame, local.B)));
  const movedFrame = moved.windows.find(w => w.id === originals.B.id).frame;
  verifyGestureMotion('drag', local.B, movedFrame, 70, 40);
  local.B = movedFrame;
  await check('Observe manual B drag on page 1', 1, false, 'B');
  await fixtureShortcut(originals.B.id, 'pageLeft');
  await check('Return to original A on page 0', 0, false, 'A');
  assert(await typeToken('Type directly in A on page 0', 'A', originals.A.id, '-page-A'));
  await fixtureShortcut(originals.A.id, 'pageRight');
  await check('Return to B at its manually moved position', 1, false, 'B');
  for (let round = 1; round <= pageRoundTrips; round++) {
    await fixtureShortcut(originals.B.id, 'pageLeft');
    await check(`Comparative page round trip ${round}/${pageRoundTrips}: original A`, 0, false, 'A');
    await fixtureShortcut(originals.A.id, 'pageRight');
    await check(`Comparative page round trip ${round}/${pageRoundTrips}: original B`, 1, false, 'B');
  }
  await fixtureShortcut(originals.B.id, 'togglePause');
  await check('Pause releases both originals', 1, true);
  const paused = snapshot();
  assert.equal(paused.frontmostPID, pid);
  assert([originals.A.id, originals.B.id].includes(paused.focusedID));
  await fixtureShortcut(paused.focusedID, 'togglePause');
  await check('Resume parks only A', 1, false, 'B');
  await verifyCameraLifecycle({ ...context, mode, parkedName: 'A',
    originals: { A: originals.A, B: { ...originals.B, frame: local.B } } });
}
