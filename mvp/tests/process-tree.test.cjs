const test = require("node:test");
const assert = require("node:assert/strict");
const { parsePhysicalFootprints, parseProcessTable, selectProcessTree } = require("../dist/process-tree.js");

test("parses ps output while preserving commands with spaces", () => {
  const rows = parseProcessTable(`
  100     1  2048 /Applications/Open Wisper.app/Contents/MacOS/Open Wisper
  101   100  1024 /Applications/Open Wisper Helper
`);

  assert.deepEqual(rows, [
    { pid: 100, parentPid: 1, rssKb: 2048, command: "/Applications/Open Wisper.app/Contents/MacOS/Open Wisper" },
    { pid: 101, parentPid: 100, rssKb: 1024, command: "/Applications/Open Wisper Helper" },
  ]);
});

test("selects every nested descendant and excludes the sampler", () => {
  const rows = parseProcessTable(`
    1 0 100 launchd
  100 1 500 open-wisper
  101 100 200 renderer
  102 100 300 whisper-cli
  103 102 400 whisper-worker
  104 100 10 ps
  999 1 800 unrelated
`);

  assert.deepEqual(selectProcessTree(rows, 100, new Set([104])), [
    { pid: 100, parentPid: 1, rssKb: 500, command: "open-wisper", depth: 0 },
    { pid: 101, parentPid: 100, rssKb: 200, command: "renderer", depth: 1 },
    { pid: 102, parentPid: 100, rssKb: 300, command: "whisper-cli", depth: 1 },
    { pid: 103, parentPid: 102, rssKb: 400, command: "whisper-worker", depth: 2 },
  ]);
});

test("parses current and peak physical footprint bytes", () => {
  assert.deepEqual(
    [...parsePhysicalFootprints("100 47185920 52428800\n101 7340032 8388608\n")],
    [
      [100, { currentBytes: 47_185_920, peakBytes: 52_428_800 }],
      [101, { currentBytes: 7_340_032, peakBytes: 8_388_608 }],
    ],
  );
});
