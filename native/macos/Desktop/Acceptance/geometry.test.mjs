import assert from 'node:assert/strict';
import test from 'node:test';
import { bindOriginals, insideWorkArea, planOriginals, planRapidDrags, PostReleaseGeometryGuard, verifyDestroyed, verifyGestureMotion, verifyModel } from './geometry.mjs';

const a = { id: 101, frame: { x: 72, y: 100, width: 620, height: 470 } };
const b = { id: 102, frame: { x: 360, y: 230, width: 650, height: 490 } };
const binding = { A: '11111111-1111-1111-1111-111111111111', B: '22222222-2222-2222-2222-222222222222' };
function state() {
  return { windows: [['A', a], ['B', b]].map(([name, window]) => ({ id: binding[name], pid: 1234, title: 'same title',
    originalFrame: { ...window.frame }, worldFrame: { ...window.frame }, availability: 'available' })), focusedID: binding.B };
}
test('identical titles bind through original geometry and retained UUIDs', () => {
  assert.deepEqual(bindOriginals(state(), 1234, { A: a, B: b }), binding);
  verifyModel(state(), 1234, { A: a, B: b }, binding, { windows: [b, a] }, 'B');
});
test('geometry mismatch and replacement UUID cannot pass', () => {
  const moved = state();
  moved.windows[1].worldFrame.x += 40;
  assert.throws(() => verifyModel(moved, 1234, { A: a, B: b }, binding, { windows: [a, b] }, 'B'), /worldFrame/);
  const replaced = state();
  replaced.windows[1].id = '33333333-3333-3333-3333-333333333333';
  assert.throws(() => bindOriginals(replaced, 1234, { A: a, B: b }, binding), /UUID changed/);
});
test('closed model records require unavailable state and never accept an unregistered replacement', () => {
  const closed = state();
  closed.focusedID = binding.A;
  assert.throws(() => verifyDestroyed(closed, 1234, binding), /still available/);
  closed.windows[1].availability = 'closed';
  verifyDestroyed(closed, 1234, binding);
  closed.windows.push({ ...closed.windows[1], id: '33333333-3333-3333-3333-333333333333', availability: 'available' });
  assert.throws(() => verifyDestroyed(closed, 1234, binding), /replacement/);
});
test('3440 desktop and 1280 laptop plans expose B titlebar and keep the cross-midpoint path in bounds', () => {
  for (const area of [{ x: 0, y: 30, width: 3440, height: 1318 }, { x: 0, y: 30, width: 1280, height: 750 }]) {
    const { A, B } = planOriginals(area);
    assert(A.y + A.height < B.y);
    assert(B.x + B.width / 2 < area.x + area.width / 2);
    const destination = { ...B, x: Math.ceil(area.x + area.width / 2) + 24 };
    assert(destination.x > area.x + area.width / 2);
    assert(insideWorkArea(destination, area, 24));
    assert(Math.abs(destination.x - B.x) <= 1000);
  }
});
test('real drag may exceed cursor delta but cannot be a no-op, reverse, or resize', () => {
  const before = { x: 1051, y: 518, width: 650, height: 440 };
  verifyGestureMotion('drag', before, { ...before, x: 1773 }, 693, 0);
  assert.throws(() => verifyGestureMotion('drag', before, before, 693, 0), /no-op/);
  assert.throws(() => verifyGestureMotion('drag', before, { ...before, x: 1000 }, 693, 0), /direction/);
  assert.throws(() => verifyGestureMotion('drag', before, { ...before, x: 1773, width: 660 }, 693, 0), /size/);
});
test('corner resize must change size in the requested directions and preserve origin', () => {
  verifyGestureMotion('resize', b.frame, { ...b.frame, width: 710, height: 535 }, 80, 55);
  assert.throws(() => verifyGestureMotion('resize', b.frame, b.frame, 80, 55), /no-op/);
  assert.throws(() => verifyGestureMotion('resize', b.frame, { ...b.frame, x: 365, width: 710, height: 535 }, 80, 55), /origin/);
});
test('late displacement fails even when the second frame stays to the right of the initial position', () => {
  const right = { ...b.frame, x: 1773 };
  const guard = new PostReleaseGeometryGuard(right, 200, 0);
  assert.equal(guard.observe(right, 500), undefined);
  assert(guard.observe(right, 900));
  assert.throws(() => guard.observe({ ...right, x: 1650 }, 1500), /post-release displacement/);
});
test('native motion may settle before a post-release anchor is established', () => {
  const guard = new PostReleaseGeometryGuard(b.frame, 100, 0);
  assert.equal(guard.observe({ ...b.frame, x: 400 }, 350), undefined);
  assert(guard.observe({ ...b.frame, x: 400 }, 850));
});
test('rapid drags exceed small snapping distances and remain portable and disjoint from A', () => {
  for (const area of [{ x: 0, y: 30, width: 3440, height: 1318 }, { x: 0, y: 30, width: 1280, height: 750 }]) {
    const { A, B } = planOriginals(area);
    const moved = { ...B, x: Math.ceil(area.x + area.width / 2), y: B.y - 18,
      width: B.width + 55, height: B.height + 55 };
    const segments = planRapidDrags(moved, A, area);
    assert(segments.every(segment => segment.dx <= -20 && segment.dy <= -20));
    if (area.width === 3440) assert.deepEqual(segments.map(({ dx, dy }) => ({ dx, dy })), [{ dx: -64, dy: -37 }, { dx: -54, dy: -32 }]);
  }
});
