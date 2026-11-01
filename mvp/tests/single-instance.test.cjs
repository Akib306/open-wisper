const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { createRequire } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

function launch(primary) {
  const events = new Map();
  const calls = { quit: 0, ready: 0, show: 0, focus: 0, windows: 0, names: [], paths: [], directories: [] };
  const app = {
    isPackaged: true,
    setName: name => calls.names.push(name),
    getPath: name => name === 'appData' ? '/fixture/Application Support' : '/fixture/other',
    setPath: (name, value) => calls.paths.push([name, value]),
    requestSingleInstanceLock: () => primary,
    quit: () => calls.quit++,
    on: (name, callback) => events.set(name, callback),
    whenReady: () => { calls.ready++; return { then: () => {} }; },
  };
  class BrowserWindow {
    constructor() { calls.windows++; }
    webContents = { setWindowOpenHandler() {} };
    loadFile() {}
    on() {}
    show() { calls.show++; }
    focus() { calls.focus++; }
  }
  const entry = path.resolve(__dirname, '../dist/main.js');
  const localRequire = createRequire(entry);
  const context = {
    require: name => name === 'electron' ? { app, BrowserWindow } : name === 'node:fs'
      ? { ...localRequire(name), mkdirSync: location => calls.directories.push(location) } : localRequire(name),
    exports: {}, __dirname: path.dirname(entry), process, console, setTimeout, clearTimeout,
  };
  vm.runInNewContext(readFileSync(entry, 'utf8'), context, { filename: entry });
  return { calls, events };
}

test('a duplicate Electron launch quits before initialization and registers no activation handler', () => {
  const { calls, events } = launch(false);
  assert.equal(calls.quit, 1);
  assert.equal(calls.ready, 0);
  assert.equal(events.has('activate'), false);
  assert.equal(calls.show, 0);
});

test('the primary instance handles a second launch by showing its existing window', () => {
  const { calls, events } = launch(true);
  assert.equal(calls.ready, 1);
  assert.equal(calls.quit, 0);
  assert.equal(typeof events.get('second-instance'), 'function');
  events.get('second-instance')();
  events.get('second-instance')();
  assert.equal(calls.show, 2);
  assert.equal(calls.focus, 2);
  assert.equal(calls.windows, 1);
  assert.deepEqual(calls.names, ['Open Wisper Electron']);
  assert.deepEqual(calls.paths, [['userData', '/fixture/Application Support/open-wisper']]);
  assert.deepEqual(calls.directories, ['/fixture/Application Support/open-wisper']);
});
