import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { runInNewContext } from "node:vm";

const source = await readFile(
  new URL("../../android/web/bridge.js", import.meta.url),
  "utf8",
);

test("preview snapshots coalesce until rendering resumes; save replies bypass the frame queue", () => {
  const frames = [];
  let listener;
  const window = {
    parent: {},
    location: { origin: "http://localhost:1432" },
    addEventListener: (_, callback) => {
      listener = callback;
    },
  };
  runInNewContext(source, {
    window,
    requestAnimationFrame: (callback) => frames.push(callback),
  });
  const received = [];
  window.registerDeskbarEditor((value) => received.push(JSON.parse(value)));
  const send = (message, source = window.parent) =>
    listener({
      source,
      origin: window.location.origin,
      data: { channel: "deskbar-editor", message: JSON.stringify(message) },
    });
  for (let revision = 0; revision < 10000; revision++)
    send({ type: "state", revision });
  assert.equal(frames.length, 1);
  assert.equal(received.length, 0);
  send({ type: "saved", requestId: 1, revision: 10000 });
  assert.deepEqual(received, [
    { type: "saved", requestId: 1, revision: 10000 },
  ]);
  send({ type: "state", revision: -1 }, {});
  frames.shift()();
  assert.deepEqual(received.at(-1), { type: "state", revision: 9999 });
  send({ type: "state", revision: 10001 });
  assert.equal(frames.length, 1);
  frames.shift()();
  assert.deepEqual(received.at(-1), { type: "state", revision: 10001 });
});
