import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { Window } from "happy-dom";
import ts from "typescript";

const require = createRequire(import.meta.url);
const { outputText } = ts.transpileModule(
  await readFile(
    new URL("../src/WorkbenchEditor.tsx", import.meta.url),
    "utf8",
  ),
  {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2022,
      jsx: ts.JsxEmit.ReactJSX,
    },
  },
);

const device = (id, display = null) => ({
  id,
  name: "Android 工作台",
  display,
  layout_revision: 0,
});

function deferred() {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

async function editor(t, initialDevices, handle = () => ({})) {
  const window = new Window({
    url: "http://localhost:1432",
    settings: { disableIframePageLoading: true },
  });
  const previous = new Map();
  for (const [name, value] of Object.entries({
    window,
    document: window.document,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { value, configurable: true });
  }
  const intervals = new Map();
  const timeouts = new Map();
  let timerId = 0;
  window.setInterval = (callback) => {
    intervals.set(++timerId, callback);
    return timerId;
  };
  window.clearInterval = (id) => intervals.delete(id);
  window.setTimeout = (callback) => {
    timeouts.set(++timerId, callback);
    return timerId;
  };
  window.clearTimeout = (id) => timeouts.delete(id);
  const calls = [];
  const exports = {};
  new Function("require", "exports", outputText)(
    (name) =>
      name === "./api"
        ? {
            call: async (command, args) => {
              calls.push({ command, args });
              return handle(command, args);
            },
          }
        : require(name),
    exports,
  );
  const container = window.document.createElement("div");
  window.document.body.append(container);
  const root = createRoot(container);
  t.after(async () => {
    await act(async () => root.unmount());
    assert.equal(intervals.size, 0);
    assert.equal(timeouts.size, 0);
    await window.happyDOM.abort();
    for (const [name, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else delete globalThis[name];
    }
  });
  const render = async (devices) =>
    act(async () => {
      root.render(
        React.createElement(exports.WorkbenchEditor, { status: { devices } }),
      );
    });
  const message = async (frame, payload) =>
    act(async () => {
      window.dispatchEvent(
        new window.MessageEvent("message", {
          source: frame.contentWindow,
          origin: window.location.origin,
          data: { channel: "deskbar-editor", message: JSON.stringify(payload) },
        }),
      );
    });
  const frame = () => {
    const element = container.querySelector("iframe");
    // The renderer remains unloaded in DOM tests; model its message endpoint.
    if (!element.contentWindow) {
      Object.defineProperty(element, "contentWindow", { value: {} });
    }
    const sent = [];
    element.contentWindow.postMessage = (payload) =>
      sent.push(JSON.parse(payload.message));
    return { element, sent, contentWindow: element.contentWindow };
  };
  await render(initialDevices);
  return { render, message, frame, container, calls, intervals };
}

test("removing all devices while editing allows a fresh pairing with the same name", async (t) => {
  const app = await editor(t, [device("old")]);
  const old = app.frame();
  await app.message(old, { type: "ready" });
  await app.message(old, { type: "editing", value: true });
  assert.equal(
    app.container.querySelector(".editor-device-button").disabled,
    true,
  );
  await app.render([]);
  assert.equal(app.container.querySelector("iframe"), null);
  assert.match(app.container.textContent, /连接设备后即可编辑工作台/);
  assert.equal(app.intervals.size, 0);
  await app.render([device("new")]);
  const current = app.frame();
  assert.notEqual(current.element, old.element);
  assert.equal(
    app.container.querySelector('[aria-pressed="true"]').dataset.deviceId,
    "new",
  );
  assert.equal(
    app.container.querySelector(".editor-device-button").disabled,
    false,
  );
  await app.message(current, { type: "ready" });
  assert.deepEqual(
    app.calls.map(({ args }) => args.id),
    ["old", "new"],
  );
  assert.equal(app.container.querySelector('[role="alert"]'), null);
  assert.equal(app.container.querySelector('[role="status"]'), null);
});

test("replacement isolates late snapshots, stale iframe commands and cached dimensions", async (t) => {
  const pending = deferred();
  const app = await editor(
    t,
    [device("old", { width: 400, height: 800 })],
    (_command, { id }) => (id === "old" ? pending.promise : { target: "new" }),
  );
  const old = app.frame();
  await app.message(old, { type: "ready" });
  await app.message(old, { type: "editing", value: true });
  await app.render([device("new")]);
  const current = app.frame();
  await app.message(old, { type: "save", layout: "old-layout" });
  await app.message(old, { type: "editing", value: true });
  await app.message(current, { type: "ready" });
  await act(async () => pending.resolve({ target: "old" }));
  assert.deepEqual(current.sent, [
    { type: "state", snapshot: { target: "new" }, display: null },
  ]);
  assert.equal(
    app.container.querySelector(".editor-device-button").disabled,
    false,
  );
  assert.deepEqual(
    app.calls.map(({ args }) => args.id),
    ["old", "new"],
  );
});

test("an old save cannot acknowledge or block saves for a newly paired device", async (t) => {
  const pending = deferred();
  const app = await editor(t, [device("old")], (command, { id }) =>
    command === "save_layout" ? (id === "old" ? pending.promise : 7) : {},
  );
  const old = app.frame();
  await app.message(old, { type: "ready" });
  await app.message(old, {
    type: "save",
    requestId: 1,
    layout: "old-layout",
    expectedRevision: 0,
  });
  await app.render([device("new")]);
  const current = app.frame();
  await app.message(current, { type: "ready" });
  await app.message(current, {
    type: "save",
    requestId: 1,
    layout: "new-layout",
    expectedRevision: 0,
  });
  await act(async () => pending.resolve(99));
  assert.deepEqual(
    app.calls
      .filter(({ command }) => command === "save_layout")
      .map(({ args }) => [args.id, args.layout]),
    [
      ["old", "old-layout"],
      ["new", "new-layout"],
    ],
  );
  assert.deepEqual(
    current.sent.filter(({ type }) => type === "saved"),
    [{ type: "saved", requestId: 1, revision: 7 }],
  );
});

test("ordinary status refreshes preserve editing, while removal selects a remaining device", async (t) => {
  const app = await editor(t, [device("a"), device("b")]);
  const original = app.frame();
  await app.message(original, { type: "ready" });
  await app.message(original, { type: "editing", value: true });
  await app.render([device("a"), device("b")]);
  assert.equal(app.container.querySelector("iframe"), original.element);
  assert.equal(
    app.container.querySelector(".editor-device-button").disabled,
    true,
  );
  await app.render([device("b")]);
  assert.equal(
    app.container.querySelector('[aria-pressed="true"]').dataset.deviceId,
    "b",
  );
  assert.equal(
    app.container.querySelector(".editor-device-button").disabled,
    false,
  );
  await app.render([device("c"), device("b")]);
  assert.equal(
    app.container.querySelector('[aria-pressed="true"]').dataset.deviceId,
    "b",
  );
});

test("flat device buttons distinguish same-name devices and switch only outside editing", async (t) => {
  const app = await editor(t, [
    device("12345678-first"),
    device("87654321-second"),
  ]);
  assert.equal(app.container.querySelector("select"), null);
  const buttons = () => [
    ...app.container.querySelectorAll(".editor-device-button"),
  ];
  assert.deepEqual(
    buttons().map((button) => button.getAttribute("aria-label")),
    ["Android 工作台 · 12345678", "Android 工作台 · 87654321"],
  );
  assert.deepEqual(
    buttons().map((button) => button.querySelector("code").textContent),
    ["#12345678", "#87654321"],
  );
  await act(async () => buttons()[1].click());
  assert.equal(buttons()[1].getAttribute("aria-pressed"), "true");
  const current = app.frame();
  await app.message(current, { type: "ready" });
  await app.message(current, { type: "editing", value: true });
  assert.equal(
    buttons().every((button) => button.disabled),
    true,
  );
  await act(async () => buttons()[0].click());
  assert.equal(buttons()[1].getAttribute("aria-pressed"), "true");
  await app.message(current, { type: "editing", value: false });
  await act(async () => buttons()[0].click());
  assert.equal(buttons()[0].getAttribute("aria-pressed"), "true");
});
