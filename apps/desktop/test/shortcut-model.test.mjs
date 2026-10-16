import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import ts from "typescript";

const source = await readFile(
  new URL("../src/shortcut-model.ts", import.meta.url),
  "utf8",
);
const { outputText } = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.ESNext,
    target: ts.ScriptTarget.ES2022,
  },
});
const { applyWebsiteInfo, canFetchWebsiteInfo, duplicateShortcut } =
  await import(
    `data:text/javascript;base64,${Buffer.from(outputText).toString("base64")}`
  );
const item = {
  id: "one",
  name: "",
  kind: "url",
  target: "https://example.com",
  icon_png: "",
};
const info = { title: "Example", icon: "pixels", warning: null };

test("website lookup requires a complete web URL without credentials", () => {
  for (const url of [
    "https://",
    "example.com",
    "file:///tmp/icon",
    "codex://open",
    "https://user:secret@example.com",
  ])
    assert.equal(canFetchWebsiteInfo(url), false, url);
  assert.equal(canFetchWebsiteInfo(" https://example.com/page "), true);
  assert.equal(canFetchWebsiteInfo("http://localhost:8080"), true);
});
test("website result fills missing name and image", () => {
  assert.deepEqual(applyWebsiteInfo(item, item, info), {
    ...item,
    name: "Example",
    icon_png: "pixels",
  });
});
test("late website results preserve edited fields and ignore a changed URL or editor", () => {
  const edited = { ...item, name: "我的网站", icon_png: "manual" };
  assert.deepEqual(applyWebsiteInfo(edited, item, info), edited);
  for (const changed of [
    { ...item, target: "https://other.example" },
    { ...item, id: "two" },
  ])
    assert.equal(applyWebsiteInfo(changed, item, info), changed);
});
test("a missing remote icon preserves the current image and a chosen name", () => {
  const named = { ...item, name: "我的名称", icon_png: "manual" };
  assert.deepEqual(
    applyWebsiteInfo(named, named, { ...info, icon: "" }),
    named,
  );
});
test("duplicate detection permits editing itself but rejects another identical target", () => {
  assert.equal(duplicateShortcut([item], item), false);
  assert.equal(duplicateShortcut([item], { ...item, id: "two" }), true);
  assert.equal(
    duplicateShortcut([item], {
      ...item,
      id: "two",
      target: "https://other.example",
    }),
    false,
  );
});
