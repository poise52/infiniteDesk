import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { lstat, readFile, realpath } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { framesMatch } from './geometry.mjs';

const root = fileURLToPath(new URL('../../../../', import.meta.url));

function processExists(pid) {
  try { process.kill(pid, 0); return true; }
  catch (error) { if (error.code === 'ESRCH') return false; throw error; }
}

function verifyPhysical(actual, originals, parkedName) {
  assert(actual && Array.isArray(actual.windows) && Array.isArray(actual.onscreenIDs),
    'Lifecycle requires independent native windows and on-screen IDs');
  for (const [name, original] of Object.entries(originals)) {
    const window = actual.windows.find(item => item.id === original.id);
    assert(window, `Lifecycle lost original ${name} CG identity`);
    assert(framesMatch(window.frame, original.frame), `Lifecycle changed original ${name} physical bounds`);
    assert.equal(window.minimized, name === parkedName, `Unexpected original ${name} minimized state`);
    assert.equal(actual.onscreenIDs.includes(original.id), name !== parkedName,
      `Unexpected original ${name} on-screen visibility`);
  }
}

export async function verifyCameraLifecycle({
  mode, readModel, native, pid, originals, parkedName, statePath, journalPath,
  session, snapshot, eventually, report, restoreFixture,
}) {
  assert(['quit', 'crash'].includes(mode), 'Lifecycle mode must be quit or crash');
  assert.equal(typeof session, 'string');
  assert(/^[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}$/i.test(session),
    'Lifecycle needs a unique random UUID test session challenge');
  assert(isAbsolute(statePath) && isAbsolute(journalPath), 'Lifecycle requires absolute isolated paths');
  assert.notEqual(resolve(statePath), resolve(journalPath), 'State and journal must be separate files');
  const stateDirectory = await realpath(dirname(statePath));
  assert.equal(await realpath(dirname(journalPath)), stateDirectory, 'Test journal must share the isolated state directory');
  const directoryInfo = await lstat(stateDirectory);
  assert(directoryInfo.isDirectory() && directoryInfo.uid === process.getuid()
    && (directoryInfo.mode & 0o022) === 0, 'Lifecycle requires an owned directory without shared write access');
  assert(!stateDirectory.includes('/Library/Application Support/'), 'Lifecycle must not use the normal recovery directory');
  assert(originals.A && originals.B && Object.keys(originals).length === 2, 'Lifecycle requires only the two owned originals');
  assert(Object.hasOwn(originals, parkedName), 'Lifecycle requires an explicitly named parked fixture');
  if (mode === 'crash') assert.equal(typeof restoreFixture, 'function', 'Crash recovery requires the owned fixture restore callback');

  const lifecycle = { mode, status: 'RUNNING', evidence: [], cleanup: { status: 'NOT_NEEDED' } };
  report.camera ??= {};
  report.camera.lifecycle = lifecycle;
  let oldIdentity;
  let restartedPID;
  let launched = false;
  let failure;
  const driverArguments = managerPID => [managerPID, session, statePath, journalPath];

  async function identity(managerPID) {
    assert(Number.isInteger(managerPID) && managerPID > 1 && managerPID !== process.pid,
      'Refusing an invalid manager PID');
    const receipt = await native('manager-identity', ...driverArguments(managerPID));
    assert.equal(receipt.pid, managerPID, 'Driver identified a different manager PID');
    assert.equal(receipt.testSession, session, 'Driver did not verify the launch challenge');
    assert.equal(resolve(receipt.statePath), resolve(statePath), 'Driver state path mismatch');
    assert.equal(resolve(receipt.journalPath), resolve(journalPath), 'Driver journal path mismatch');
    const bundle = await realpath(receipt.bundlePath);
    const builds = await realpath(join(root, 'target/InfiniteDesk-builds'));
    assert(/^build\.[^/]+\/InfiniteDesk\.app$/.test(relative(builds, bundle)),
      'Refusing a manager outside the local versioned development bundles');
    const executable = await realpath(receipt.executablePath);
    assert.equal(executable, join(bundle, 'Contents/MacOS/InfiniteDesk'),
      'Manager executable does not belong to the validated exact bundle');
    assert(Number.isSafeInteger(receipt.processIdentity?.seconds)
      && Number.isSafeInteger(receipt.processIdentity?.microseconds), 'Driver did not verify process birth identity');
    if (oldIdentity) {
      assert.equal(bundle, oldIdentity.bundlePath, 'Lifecycle must use the same exact development bundle');
    }
    return { ...receipt, bundlePath: bundle, executablePath: executable };
  }

  async function mutate(command, managerIdentity) {
    const current = await identity(managerIdentity.pid);
    assert.deepEqual(current.processIdentity, managerIdentity.processIdentity,
      'The manager PID was replaced before lifecycle mutation');
    const receipt = await native(command, ...driverArguments(current.pid));
    assert.equal(receipt.pid, current.pid);
    assert.equal(receipt.testSession, session);
    assert.deepEqual(receipt.processIdentity, current.processIdentity,
      'Lifecycle command targeted a different process incarnation');
    assert.equal(receipt.accepted, true, `${command} was not accepted`);
    lifecycle.evidence.push({ command, receipt, at: new Date().toISOString() });
    return receipt;
  }

  async function journal() {
    let content;
    try { content = await readFile(journalPath, 'utf8'); }
    catch (error) { if (error.code === 'ENOENT') return { version: 1, entries: [] }; throw error; }
    const value = JSON.parse(content);
    assert.equal(value.version, 1);
    assert(Array.isArray(value.entries), 'Recovery journal has no entries array');
    assert(value.entries.every(entry => entry.pid === pid), 'Refusing lifecycle with unrelated recovery entries');
    return value;
  }

  async function exited(managerPID) {
    await eventually('The owned manager did not exit', async () => !processExists(managerPID), Boolean, 8_000);
  }

  async function findOwnedRelaunch() {
    const listing = spawnSync('/bin/ps', ['-axww', '-o', 'pid=,comm='], { encoding: 'utf8', timeout: 5_000 });
    if (listing.error) throw listing.error;
    assert.equal(listing.status, 0, 'Could not inspect manager processes during cleanup');
    const candidates = listing.stdout.split('\n').flatMap(line => {
      const match = /^\s*(\d+)\s+(.+)$/.exec(line);
      return match && match[2] === oldIdentity.executablePath ? [Number(match[1])] : [];
    });
    const owned = [];
    const untouched = [];
    for (const candidate of candidates) {
      try { owned.push(await identity(candidate)); }
      catch (error) {
        if (processExists(candidate)) untouched.push({ pid: candidate, reason: String(error) });
      }
    }
    lifecycle.cleanup.untouchedProcesses = untouched;
    assert(owned.length <= 1, 'Multiple manager processes claim the unique lifecycle launch challenge');
    assert.equal(untouched.length, 0, 'Cleanup left an unverified process untouched; inspect its identity before any action');
    return owned[0];
  }

  async function awaitRestored(description) {
    const result = await eventually(description, async () => {
      try {
        const actual = await snapshot();
        verifyPhysical(actual, originals);
        return { actual };
      } catch (error) { return { error: String(error) }; }
    }, observation => Boolean(observation.actual), 8_000);
    return result.actual;
  }

  try {
    const model = await readModel();
    assert.equal(model.testSession, session, 'Snapshot does not belong to this test launch');
    assert.equal(model.camera?.busy, false, 'Lifecycle must start after camera operations settle');
    assert.equal(model.camera?.paused, false, 'Lifecycle requires an active workspace');
    assert.equal(model.camera?.pendingRecoveryCount, 0, 'Lifecycle must start without interrupted recovery entries');
    assert(model.windows.length === 2 && model.windows.every(window => window.pid === pid),
      'Refusing lifecycle with registrations outside the two owned fixture windows');
    assert.equal(model.windows.filter(window => window.parked).length, 1, 'Lifecycle requires exactly one parked original');
    oldIdentity = await identity(model.managerPID);
    lifecycle.originalManager = oldIdentity;
    const before = await snapshot();
    verifyPhysical(before, originals, parkedName);
    const beforeJournal = await journal();
    assert(beforeJournal.entries.length > 0, 'Parking did not save a recovery entry');
    const modelIDs = new Set(model.windows.map(window => window.id.toLowerCase()));
    assert(beforeJournal.entries.every(entry => modelIDs.has(entry.id.toLowerCase())),
      'Recovery journal contains a window outside the fresh owned manager model');
    lifecycle.before = { model, native: before, journal: beforeJournal };

    if (mode === 'quit') {
      await mutate('manager-quit', oldIdentity);
      await exited(oldIdentity.pid);
      const restored = await awaitRestored('Quit did not restore both original windows');
      const emptyJournal = await eventually('Quit left pending recovery entries', journal, value => value.entries.length === 0);
      lifecycle.after = { native: restored, journal: emptyJournal, managerExited: true };
    } else {
      await mutate('manager-kill', oldIdentity);
      await exited(oldIdentity.pid);
      verifyPhysical(await snapshot(), originals, parkedName);
      assert.deepEqual(await journal(), beforeJournal, 'The crash changed saved recovery records');
      launched = true;
      const launch = spawnSync('/usr/bin/open', [
        '-n', '-g', '--env', `INFINITEDESK_TEST_STATE_PATH=${statePath}`,
        '--env', `INFINITEDESK_TEST_CAMERA_JOURNAL_PATH=${journalPath}`,
        '--env', `INFINITEDESK_TEST_SESSION=${session}`, oldIdentity.bundlePath,
      ], { encoding: 'utf8', timeout: 8_000 });
      if (launch.error) throw launch.error;
      assert.equal(launch.status, 0, `Exact test bundle relaunch failed: ${launch.stderr}`);
      const recovery = await eventually('Restart did not report interrupted recovery', async () => {
        try { return await readModel(); } catch { return undefined; }
      }, value => value?.testSession === session && Number.isInteger(value.managerPID)
        && value.managerPID !== oldIdentity.pid && value.camera?.pendingRecoveryCount > 0
        && value.camera?.paused === true && value.camera?.busy === false, 8_000);
      restartedPID = recovery.managerPID;
      const restartedIdentity = await identity(restartedPID);
      assert.notDeepEqual(restartedIdentity.processIdentity, oldIdentity.processIdentity,
        'Relaunch did not create a fresh process incarnation');
      assert.equal(recovery.windows.length, 0, 'Restart guessed registrations for interrupted windows');
      lifecycle.restartedManager = restartedIdentity;
      lifecycle.recovery = { model: recovery, samples: [] };
      const observeSince = Date.now();
      await eventually('Recovery moved windows without explicit user selection', async () => {
        const actual = await snapshot();
        verifyPhysical(actual, originals, parkedName);
        lifecycle.recovery.samples.push({ at: new Date().toISOString(), native: actual });
        return Date.now() - observeSince;
      }, duration => duration >= 1_000, 4_000);
      assert.deepEqual(await journal(), beforeJournal, 'Restart rewrote interrupted recovery records');
      await restoreFixture(parkedName);
      const restored = await awaitRestored('Manual fixture recovery did not restore both originals');
      const pending = await readModel();
      assert.equal(pending.managerPID, restartedPID);
      assert.equal(pending.testSession, session);
      assert.equal(pending.camera.pendingRecoveryCount, beforeJournal.entries.length,
        'External manual restoration silently acknowledged the journal');
      assert.deepEqual(await journal(), beforeJournal, 'Fixture restoration edited the recovery journal');
      lifecycle.after = { native: restored, model: pending, journal: beforeJournal,
        recovery: 'Owned fixture restored explicitly; interrupted records preserved for user acknowledgement' };
    }
    lifecycle.status = 'PASS';
  } catch (error) {
    lifecycle.status = 'FAIL';
    lifecycle.error = error.stack ?? String(error);
    failure = error;
  } finally {
    if (launched) {
      lifecycle.cleanup.status = 'RUNNING';
      try {
        const owned = await findOwnedRelaunch();
        if (owned) {
          restartedPID = owned.pid;
          await mutate('manager-quit', owned);
          await exited(restartedPID);
        }
        lifecycle.cleanup.status = 'PASS';
      } catch (error) {
        lifecycle.cleanup.status = 'FAIL';
        lifecycle.cleanup.error = error.stack ?? String(error);
        lifecycle.status = 'FAIL';
        failure ??= error;
      }
    }
    lifecycle.finished = new Date().toISOString();
  }
  if (failure) throw failure;
  return lifecycle;
}
