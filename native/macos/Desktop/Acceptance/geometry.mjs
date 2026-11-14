import assert from 'node:assert/strict';

export function validFrame(value) {
  return value && ['x', 'y', 'width', 'height'].every(key => typeof value[key] === 'number' && Number.isFinite(value[key]))
    && value.width > 0 && value.height > 0;
}

export function framesMatch(a, b) {
  return validFrame(a) && validFrame(b)
    && ['x', 'y', 'width', 'height'].every(key => Math.abs(a[key] - b[key]) <= 1);
}

export function insideWorkArea(frame, area, margin = 0) {
  return validFrame(frame) && validFrame(area) && frame.x >= area.x + margin && frame.y >= area.y + margin
    && frame.x + frame.width <= area.x + area.width - margin
    && frame.y + frame.height <= area.y + area.height - margin;
}

export function verifyGestureMotion(kind, before, after, dx, dy, allowUnchangedConstraint = false) {
  assert(validFrame(before) && validFrame(after), 'Gesture requires valid independent native frames');
  if (kind === 'click') {
    assert(framesMatch(before, after), 'A titlebar click changed the native frame');
    return;
  }
  const directed = (requested, actual, axis) => {
    if (requested === 0) return;
    const minimum = Math.min(12, Math.max(3, Math.abs(requested) * 0.05));
    assert(Math.sign(requested) * actual >= minimum, `Gesture ${axis} was a no-op or moved against the requested direction`);
  };
  if (kind === 'drag') {
    assert(Math.abs(before.width - after.width) <= 1 && Math.abs(before.height - after.height) <= 1,
      'Titlebar drag changed the native size');
    directed(dx, after.x - before.x, 'x');
    directed(dy, after.y - before.y, 'y');
    assert(!framesMatch(before, after), 'Titlebar drag was a no-op');
  } else {
    assert.equal(kind, 'resize');
    assert(Math.abs(before.x - after.x) <= 1 && Math.abs(before.y - after.y) <= 1,
      'Corner resize changed the native origin');
    if (allowUnchangedConstraint && framesMatch(before, after)) return;
    directed(dx, after.width - before.width, 'width');
    directed(dy, after.height - before.height, 'height');
    assert(!framesMatch(before, after), 'Corner resize was a no-op');
  }
}

export class PostReleaseGeometryGuard {
  constructor(frame, observedAt, releasedAt) {
    this.candidate = { ...frame };
    this.candidateSince = observedAt;
    this.releasedAt = releasedAt;
    this.anchor = undefined;
  }
  observe(frame, now) {
    if (this.anchor) {
      assert(!['x', 'y', 'width', 'height'].some(key => Math.abs(frame[key] - this.anchor.frame[key]) >= 8),
        'Significant post-release displacement after independently observed stable native geometry');
    }
    if (!framesMatch(this.candidate, frame)) {
      this.candidate = { ...frame };
      this.candidateSince = now;
    }
    if (!this.anchor && now - this.releasedAt >= 750 && now - this.candidateSince >= 300) {
      this.anchor = { frame: { ...frame }, at: now };
    }
    return this.anchor;
  }
}

export function planOriginals(area) {
  assert(validFrame(area), 'Missing usable main-display work area');
  const gap = 24;
  const width = Math.min(650, Math.floor(area.width * 0.42));
  const height = Math.min(440, Math.floor((area.height - 3 * gap - 100) / 2));
  assert(width >= 500 && height >= 260, 'Stage 2 requires a work area of at least about 1200×692 points');
  const A = { x: area.x + gap, y: area.y + gap, width: width - 20, height };
  const B = { x: Math.round(area.x + area.width * 0.4 - width / 2), y: area.y + height + 2 * gap, width, height };
  assert(insideWorkArea(A, area, gap) && insideWorkArea(B, area, gap), 'Original windows do not fit the work area');
  assert(A.y + A.height < B.y, 'Original A/B must not overlap');
  const targetX = Math.ceil(area.x + area.width / 2) + gap;
  assert(Math.abs(targetX - B.x) <= 1000, 'Cross-midpoint drag exceeds the driver guard');
  return { A, B };
}

export function planRapidDrags(frame, aFrame, area) {
  const leftBudget = Math.floor(frame.x - aFrame.x - aFrame.width - 24);
  const upBudget = Math.floor(frame.y - area.y - 16);
  const xScale = Math.min(1, leftBudget / 118);
  const yScale = Math.min(1, upBudget / 69);
  const segments = [
    { dx: -Math.floor(64 * xScale), dy: -Math.floor(37 * yScale), durationMS: 150 },
    { dx: -Math.floor(54 * xScale), dy: -Math.floor(32 * yScale), durationMS: 150 },
  ];
  let planned = { ...frame };
  for (const segment of segments) {
    assert(segment.dx <= -20 && segment.dy <= -20, 'Insufficient safe room for meaningful consecutive drags');
    planned = { ...planned, x: planned.x + segment.dx, y: planned.y + segment.dy };
    assert(insideWorkArea(planned, area, 16), 'Consecutive drag path leaves the work area');
    assert(planned.x >= aFrame.x + aFrame.width + 24, 'Consecutive drag path overlaps original A');
  }
  return segments;
}

export function validateState(state) {
  assert(state && Array.isArray(state.windows), 'Test state must contain a windows array');
  const ids = new Set();
  for (const window of state.windows) {
    assert(typeof window.id === 'string' && /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(window.id), 'Invalid model UUID');
    assert(!ids.has(window.id), 'Duplicate model UUID');
    ids.add(window.id);
    assert(Number.isInteger(window.pid) && window.pid > 1, 'Invalid model PID');
    assert(typeof window.title === 'string', 'Missing model title');
    assert(validFrame(window.originalFrame) && validFrame(window.worldFrame), 'Invalid model frame');
  }
  assert(state.focusedID === undefined || typeof state.focusedID === 'string', 'Invalid focused model UUID');
  return state;
}

export function bindOriginals(state, pid, originals, previous) {
  validateState(state);
  const own = state.windows.filter(window => window.pid === pid);
  assert.equal(own.length, 2, 'Expected exactly two registered disposable model windows');
  const binding = {};
  for (const name of ['A', 'B']) {
    const candidates = own.filter(window => framesMatch(window.originalFrame, originals[name].frame));
    assert.equal(candidates.length, 1, `Original ${name} frame must identify exactly one model UUID`);
    assert(!['unavailable', 'closed'].includes(candidates[0].availability), `Original ${name} is unavailable`);
    binding[name] = candidates[0].id;
    if (previous) assert.equal(binding[name], previous[name], `Original ${name} model UUID changed`);
  }
  assert.notEqual(binding.A, binding.B);
  return binding;
}

export function verifyModel(state, pid, originals, binding, native, focusedName) {
  bindOriginals(state, pid, originals, binding);
  for (const name of ['A', 'B']) {
    const record = state.windows.find(window => window.id === binding[name]);
    const actual = native.windows.find(window => window.id === originals[name].id);
    assert(actual, `Original ${name} native CG ID disappeared`);
    assert(framesMatch(record.worldFrame, actual.frame), `Original ${name} model worldFrame differs from independently read AX frame`);
  }
  assert.equal(state.focusedID, binding[focusedName], `Model focusedID must identify original ${focusedName}`);
}

export function verifyDestroyed(state, pid, binding) {
  validateState(state);
  const closed = state.windows.find(window => window.id === binding.B);
  assert(!closed || ['unavailable', 'closed'].includes(closed.availability), 'Destroyed B is still available in the model');
  const own = state.windows.filter(window => window.pid === pid);
  assert(own.some(window => window.id === binding.A), 'Original A disappeared from the model');
  assert(own.every(window => window.id === binding.A || window.id === binding.B), 'Unregistered replacement was added to the model');
  assert.equal(state.focusedID, binding.A, 'Destroyed/replacement B took the model focusedID');
}
