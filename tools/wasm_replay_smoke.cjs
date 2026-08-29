// Runs the EXACT emitted wasm module headless under Node against a committed
// fixture replay. wasm32-only failures -- integer traps, address-space
// exhaustion, a bad free through -d:useMalloc -- are invisible to the native
// test shards, and the bundle's own browser smoke only proves the page draws.
//
//   node tools/wasm_replay_smoke.cjs <dist dir> <replay path> [frames]
//
// It loads rware_replay.js (non-modularized, ENVIRONMENT includes node), calls
// rware_load_replay on the bytes, steps rware_frame the requested number of
// times, and fails if any frame returns < 0, if the packet is ever empty, or if
// rware_mismatch_tick ever reports a divergence.
'use strict';

const fs = require('fs');
const path = require('path');

const distDir = process.argv[2] || 'replay-viewer/dist';
const replayPath = process.argv[3] || 'tests/replays/rware.replay';
const frames = Number(process.argv[4] || 400);

const modulePath = path.resolve(distDir, 'rware_replay.js');
if (!fs.existsSync(modulePath)) {
  console.error(`missing ${modulePath}`);
  process.exit(1);
}

// The bundle is injected below with `Module` as a function parameter -- a
// plain require() cannot configure it: under the CommonJS wrapper the
// emitted `var Module = typeof Module != "undefined" ? Module : {}` declares
// a new function-scoped binding that shadows any global we set, so it sees
// its own hoisted `undefined`, discards this object and starts from `{}`.
// locateFile and onRuntimeInitialized were silently dropped that way, run()
// never fired, and the smoke exited 0 having tested nothing.
const Module = {
  locateFile: (file) => path.resolve(distDir, file),
  onAbort: (what) => {
    console.error(`wasm aborted: ${what}`);
    process.exit(1);
  },
  onRuntimeInitialized: () => { run(); },
};

function decode(ptrFn, lenFn) {
  const length = Module[lenFn]();
  if (!length) return '';
  const pointer = Module[ptrFn]();
  return Buffer.from(Module.HEAPU8.slice(pointer, pointer + length))
    .toString('utf8');
}

function run() {
  const bytes = fs.readFileSync(replayPath);
  const pointer = Module._malloc(bytes.length);
  Module.HEAPU8.set(bytes, pointer);
  const loaded = Module._rware_load_replay(pointer, bytes.length);
  Module._free(pointer);
  if (!loaded) {
    console.error('rware_load_replay failed: ' +
      (decode('_rware_error_ptr', '_rware_error_len') ||
       decode('_rware_stage_ptr', '_rware_stage_len')));
    process.exit(1);
  }
  let smallest = Infinity;
  for (let i = 0; i < frames; i++) {
    if (Module._rware_frame() < 0) {
      console.error('rware_frame failed: ' +
        decode('_rware_error_ptr', '_rware_error_len'));
      process.exit(1);
    }
    const length = Module._rware_packet_len();
    if (!length) {
      console.error(`empty packet at frame ${i}`);
      process.exit(1);
    }
    smallest = Math.min(smallest, length);
  }
  const mismatch = Module._rware_mismatch_tick();
  if (mismatch >= 0) {
    console.error(`replay hash mismatch at tick ${mismatch}`);
    process.exit(1);
  }
  const packet = JSON.parse(decode('_rware_packet_ptr', '_rware_packet_len'));
  if (!packet.rw || !Array.isArray(packet.rw.robots)) {
    console.error('the final packet carries no board state');
    process.exit(1);
  }
  console.log(`wasm smoke ok: ${frames} frames, smallest packet ${smallest} ` +
    `bytes, tick ${packet.rw.tick}, delivered ${packet.rw.delivered}`);
}

new Function('Module', 'require', '__filename', '__dirname',
  fs.readFileSync(modulePath, 'utf8'))(
  Module, require, modulePath, path.dirname(modulePath));
