import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import React, { act } from "react";
import { Window } from "happy-dom";
import ts from "typescript";

const require = createRequire(import.meta.url);
const { outputText } = ts.transpileModule(
  await readFile(
    new URL("../src/WorkbenchSettings.tsx", import.meta.url),
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
const permissions = (enabled) => ({
  sessions: enabled,
  quota: enabled,
  api_usage: enabled,
  shortcuts: enabled,
  open: enabled,
});

test("device bulk controls and rename preserve scope and handle failed saves", async () => {
  const window = new Window();
  const previous = new Map();
  for (const [key, value] of Object.entries({
    window,
    document: window.document,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { value, configurable: true });
  }
  const calls = [];
  let fail = false;
  let error;
  let pendingSave;
  const exports = {};
  new Function("require", "exports", outputText)(
    (name) =>
      name === "./api"
        ? {
            call: async (command, args) => {
              calls.push({ command, args });
              if (fail) throw Error("保存失败");
              if (pendingSave) await pendingSave;
            },
          }
        : name === "./Shortcuts"
          ? {}
          : require(name),
    exports,
  );
  const container = window.document.createElement("div");
  window.document.body.append(container);
  const { createRoot } = await import("react-dom/client");
  const root = createRoot(container);
  const device = {
    id: "one",
    name: "Pixel 9",
    permissions: permissions(false),
  };
  const render = (component, props = {}) =>
    act(async () =>
      root.render(
        React.createElement(exports[component], {
          device,
          busy: false,
          run: async (action) => {
            try {
              await action();
            } catch (e) {
              error = e;
            }
          },
          ...props,
        }),
      ),
    );
  const button = (label) =>
    [...container.querySelectorAll("button")].find(
      (b) => b.textContent.trim() === label,
    );
  const input = () => container.querySelector("input");
  const type = (value) =>
    act(async () => {
      Object.getOwnPropertyDescriptor(
        window.HTMLInputElement.prototype,
        "value",
      ).set.call(input(), value);
      input().dispatchEvent(new window.Event("input", { bubbles: true }));
    });
  const key = (key, options = {}) =>
    act(async () =>
      input().dispatchEvent(
        new window.KeyboardEvent("keydown", {
          key,
          bubbles: true,
          cancelable: true,
          ...options,
        }),
      ),
    );
  const blur = () => act(async () => input().blur());
  try {
    await render("Sharing");
    assert.equal(button("全部关闭").disabled, true);
    await act(async () => button("全部开启").click());
    assert.deepEqual(calls, [
      {
        command: "set_permissions",
        args: { id: "one", permissions: permissions(true) },
      },
    ]);
    await render("Sharing", {
      device: { ...device, permissions: permissions(true) },
    });
    assert.equal(button("全部开启").disabled, true);
    await act(async () => button("全部关闭").click());
    assert.deepEqual(calls[1].args, {
      id: "one",
      permissions: permissions(false),
    });
    await render("Sharing", { busy: true });
    assert.equal(container.querySelector("fieldset").disabled, true);
    await render("DeviceName");
    assert.equal(button("改名"), undefined);
    await act(async () => button("Pixel 9").click());
    assert.equal(window.document.activeElement, input());
    await type("放弃修改");
    await key("Escape");
    assert.equal(calls.length, 2);
    await act(async () => button("Pixel 9").click());
    await type("  ");
    await blur();
    assert.equal(calls.length, 2);
    assert.ok(button("Pixel 9"));
    await act(async () => button("Pixel 9").click());
    await type("桌面副屏");
    await key("Enter", { isComposing: true });
    assert.equal(calls.length, 2);
    fail = true;
    await key("Enter");
    assert.ok(error);
    assert.equal(input().value, "桌面副屏");
    fail = false;
    let resolveSave;
    pendingSave = new Promise((resolve) => {
      resolveSave = resolve;
    });
    await key("Enter");
    await blur();
    assert.equal(calls.length, 4, "Enter followed by blur sends only one save");
    await act(async () => resolveSave());
    pendingSave = null;
    assert.deepEqual(calls.at(-1), {
      command: "rename_device",
      args: { id: "one", name: "桌面副屏" },
    });
    assert.equal(container.querySelector("input"), null);
    await render("DeviceName", { device: { ...device, name: "桌面副屏" } });
    await act(async () => button("桌面副屏").click());
    await type("  第二个名字  ");
    await blur();
    assert.equal(calls.at(-1).args.name, "第二个名字");
    assert.equal(container.querySelector("input"), null);
  } finally {
    await act(async () => root.unmount());
    await window.happyDOM.abort();
    for (const [key, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
  }
});
