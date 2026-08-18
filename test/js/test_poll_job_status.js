// Dependency-free test for the polling deadline added to pollJobStatus in
// public/js/wpgsa/upload.js (whole-branch review finding 1: unbounded
// client polling leaves users on a spinner forever).
//
// This project has no JS test framework or npm dependencies, so this test
// uses only Node's built-in modules. It loads upload.js into a vm context
// with a minimal jQuery-like stub, fakes setTimeout/Date so the 30-minute
// deadline is crossed without a real wait, and asserts that both the
// `default:` (non-terminal status) and `.fail()` (transport error) polling
// paths stop, restore the button, and surface the job uuid once the
// deadline trips.
//
// Run with: node test/js/test_poll_job_status.js

"use strict";

const assert = require("assert");
const vm = require("vm");
const fs = require("fs");
const path = require("path");

const SOURCE_PATH = path.join(__dirname, "..", "..", "public", "js", "wpgsa", "upload.js");
const source = fs.readFileSync(SOURCE_PATH, "utf8");

function makeDeferred() {
  let state = "pending";
  let value;
  const doneCbs = [];
  const failCbs = [];

  const deferred = {
    resolve(v) {
      if (state !== "pending") return;
      state = "resolved";
      value = v;
      doneCbs.forEach((cb) => cb(value));
    },
    reject(v) {
      if (state !== "pending") return;
      state = "rejected";
      value = v;
      failCbs.forEach((cb) => cb(value));
    },
    promise() {
      return {
        done(cb) {
          if (state === "resolved") cb(value);
          else if (state === "pending") doneCbs.push(cb);
          return this;
        },
        fail(cb) {
          if (state === "rejected") cb(value);
          else if (state === "pending") failCbs.push(cb);
          return this;
        },
      };
    },
  };
  return deferred;
}

function jqueryStub() {
  const chainable = {
    on() { return chainable; },
    filestyle() { return chainable; },
    each() { return chainable; },
    append() { return chainable; },
    remove() { return chainable; },
    text() { return chainable; },
    length: 0,
  };
  const fn = function (arg) {
    if (typeof arg === "function") return; // document-ready callback: no-op
    return chainable;
  };
  fn.Deferred = makeDeferred;
  fn.each = function (arrayLike, cb) {
    // jQuery.each iterates array-likes by numeric index up to .length; the
    // stub jQuery objects here are always empty (length: 0), so this never
    // actually invokes cb, matching a real jsdom-free environment.
    const len = (arrayLike && arrayLike.length) || 0;
    for (let i = 0; i < len; i++) cb.call(arrayLike[i], i, arrayLike[i]);
  };
  return fn;
}

// Builds an isolated vm context with upload.js loaded into it, a
// controllable fake clock, and a hook for scripting $.ajax responses.
function loadContext({ ajaxHandler }) {
  let clock = 0;
  const alerts = [];

  const context = {
    console,
    alert(msg) { alerts.push(msg); },
    // Fast-forward synchronously instead of waiting 3000ms in real time.
    setTimeout(fn, ms) {
      clock += ms;
      fn();
    },
    // Only Date.now() is used by the code under test.
    Date: { now: () => clock },
  };
  context.$ = jqueryStub();
  context.$.ajax = ajaxHandler;
  context.window = context;
  vm.createContext(context);
  vm.runInContext(source, context, { filename: SOURCE_PATH });

  return {
    context,
    alerts,
    clock: () => clock,
  };
}

function fakeButton() {
  return {
    disabled: true,
    prop(name, val) {
      if (name === "disabled") this.disabled = val;
      return this;
    },
  };
}

function testStuckAtNonTerminalStatusEventuallyStopsAndAlertsWithUuid() {
  const { context, alerts, clock } = loadContext({
    ajaxHandler(opts) {
      // Every poll succeeds as a 200 but the job never leaves "running".
      opts.success({ status: "running" });
    },
  });

  const uuid = "11111111-2222-3333-4444-555555555555";
  const button = fakeButton();
  context.pollJobStatus(uuid, button);

  assert.strictEqual(alerts.length, 1, "expected exactly one alert once the deadline trips");
  assert.match(alerts[0], /did not complete/i);
  assert.ok(alerts[0].includes(uuid), "alert must include the job uuid");
  assert.strictEqual(button.disabled, false, "button must be re-enabled after timeout");
  assert.ok(clock() >= 30 * 60 * 1000, "must have polled for at least 30 minutes of wall clock");
  assert.ok(clock() < 31 * 60 * 1000, "must stop polling shortly after the deadline, not run forever");
}

function testRepeatedTransportErrorsEventuallyStopAndAlertWithUuid() {
  const { context, alerts, clock } = loadContext({
    ajaxHandler(opts) {
      // Every poll fails at the transport level (network error, 5xx, etc).
      opts.error({});
    },
  });

  const uuid = "66666666-7777-8888-9999-000000000000";
  const button = fakeButton();
  context.pollJobStatus(uuid, button);

  assert.strictEqual(alerts.length, 1, "expected exactly one alert once the deadline trips");
  assert.match(alerts[0], /did not complete/i);
  assert.ok(alerts[0].includes(uuid), "alert must include the job uuid");
  assert.strictEqual(button.disabled, false, "button must be re-enabled after timeout");
  assert.ok(clock() >= 30 * 60 * 1000, "must have polled for at least 30 minutes of wall clock");
  assert.ok(clock() < 31 * 60 * 1000, "must stop polling shortly after the deadline, not run forever");
}

function testSuccessBeforeDeadlineDoesNotAlert() {
  let calls = 0;
  const { context, alerts } = loadContext({
    ajaxHandler(opts) {
      calls += 1;
      if (calls < 3) {
        opts.success({ status: "queued" });
      } else {
        opts.success({ status: "finished" });
      }
    },
  });

  const uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
  const button = fakeButton();
  // window.open is called on success; stub it so the script doesn't throw.
  context.window.open = () => {};
  context.pollJobStatus(uuid, button);

  assert.strictEqual(alerts.length, 0, "a job that finishes before the deadline must not alert");
  assert.strictEqual(calls, 3);
}

const tests = [
  testStuckAtNonTerminalStatusEventuallyStopsAndAlertsWithUuid,
  testRepeatedTransportErrorsEventuallyStopAndAlertWithUuid,
  testSuccessBeforeDeadlineDoesNotAlert,
];

let failures = 0;
for (const t of tests) {
  try {
    t();
    console.log(`ok - ${t.name}`);
  } catch (e) {
    failures += 1;
    console.error(`not ok - ${t.name}`);
    console.error(e);
  }
}

if (failures > 0) {
  console.error(`${failures}/${tests.length} test(s) failed`);
  process.exit(1);
} else {
  console.log(`${tests.length}/${tests.length} tests passed`);
}
