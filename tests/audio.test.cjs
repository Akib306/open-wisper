const test = require("node:test");
const assert = require("node:assert/strict");
const { encodePcm16Wav, mergeFloat32Chunks, resampleLinear, rmsLevel } = require("../dist/audio.js");

test("mergeFloat32Chunks preserves order", () => {
  const merged = mergeFloat32Chunks([new Float32Array([0.1, 0.2]), new Float32Array([-0.3])]);
  assert.equal(merged.length, 3);
  assert.ok(Math.abs(merged[0] - 0.1) < 1e-6);
  assert.ok(Math.abs(merged[1] - 0.2) < 1e-6);
  assert.ok(Math.abs(merged[2] + 0.3) < 1e-6);
});

test("resampleLinear converts 48 kHz input to 16 kHz", () => {
  const input = new Float32Array(48_000);
  const output = resampleLinear(input, 48_000, 16_000);
  assert.equal(output.length, 16_000);
});

test("encodePcm16Wav writes a valid mono PCM header", () => {
  const wav = encodePcm16Wav(new Float32Array([0, 0.5, -0.5]), 16_000);
  const view = new DataView(wav);
  const ascii = (offset, length) => String.fromCharCode(...new Uint8Array(wav, offset, length));

  assert.equal(ascii(0, 4), "RIFF");
  assert.equal(ascii(8, 4), "WAVE");
  assert.equal(view.getUint16(22, true), 1);
  assert.equal(view.getUint32(24, true), 16_000);
  assert.equal(view.getUint16(34, true), 16);
  assert.equal(view.getUint32(40, true), 6);
});

test("rmsLevel reports silence and clamps loud input", () => {
  assert.equal(rmsLevel(new Float32Array(8)), 0);
  assert.equal(rmsLevel(new Float32Array(8).fill(1)), 1);
});
