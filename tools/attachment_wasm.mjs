import {
  closeSync, fstatSync, fsyncSync, linkSync, openSync, readSync, unlinkSync, writeSync,
} from 'node:fs';
import { readFile } from 'node:fs/promises';
import { dirname, basename, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const root = fileURLToPath(new URL('..', import.meta.url));
const artifact = new URL('../_build/wasm/release/build/cmd/attachmentwasm/attachmentwasm.wasm', import.meta.url);
let module;

function signature(fd) {
  const value = fstatSync(fd, { bigint: true });
  if (!value.isFile()) throw new Error('attachment source must be a regular file');
  return [value.dev, value.ino, value.size, value.mtimeNs, value.ctimeNs].join('|');
}

function exactRead(fd, offset, count) {
  const bytes = Buffer.allocUnsafe(count);
  let done = 0;
  while (done < count) {
    const n = readSync(fd, bytes, {
      offset: done, length: count - done, position: offset + BigInt(done),
    });
    if (!n) throw new Error('source ended during range read');
    done += n;
  }
  return bytes;
}

function writeAll(fd, bytes) {
  let done = 0;
  while (done < bytes.length) {
    const count = writeSync(fd, bytes, done, bytes.length - done);
    if (!count) throw new Error('payload write made no progress');
    done += count;
  }
  return done;
}

export async function attachmentRequest(path, request, { destination, build = false } = {}) {
  if ((request.operation === 'extract') !== (destination !== undefined)) {
    throw new Error('extraction requires a destination path');
  }
  if (build) {
    execFileSync('moon', ['build', 'cmd/attachmentwasm', '--target', 'wasm', '--release', '--deny-warn'], {
      cwd: root, stdio: ['ignore', 'ignore', 'pipe'],
    });
    module = undefined;
  }
  module ??= readFile(artifact).then(bytes => WebAssembly.compile(bytes));
  let input = Buffer.from(JSON.stringify(request), 'utf8');
  if (input.length > 65536) throw new Error('request exceeds 64 KiB');
  let output = Buffer.alloc(0);
  let sourceFd;
  let outputFd;
  let stage;
  let failure;
  const capture = (action, fallback) => {
    if (failure) return fallback;
    try { return action(); }
    catch (error) { failure = error; return fallback; }
  };
  try {
    sourceFd = openSync(path, 'r');
    const before = signature(sourceFd);
    const size = fstatSync(sourceFd, { bigint: true }).size;
    if (destination !== undefined) {
      const target = resolve(destination);
      stage = resolve(dirname(target), '.' + basename(target) + '.' + randomUUID() + '.part');
      outputFd = openSync(stage, 'wx');
    }
    const instance = await WebAssembly.instantiate(await module, {
      attachment_host: {
        load_range(offset, count) {
          return capture(() => {
            input = exactRead(sourceFd, BigInt.asUintN(64, offset), count);
            return input.length;
          }, -1);
        },
        get_word(offset) {
          let value = 0;
          for (let i = 0; i < 4 && offset + i < input.length; i++) {
            value |= input[offset + i] << (8 * i);
          }
          return value;
        },
        allocate_output(count) { output = Buffer.alloc(count); },
        put_word(offset, value) {
          for (let i = 0; i < 4 && offset + i < output.length; i++) {
            output[offset + i] = value >>> (8 * i);
          }
        },
        save_payload() {
          return capture(() => {
            if (outputFd === undefined) throw new Error('payload output was not opened');
            return writeAll(outputFd, output);
          }, -1);
        },
      },
    });
    instance.exports.attachment_request(size, input.length);
    if (failure) throw failure;
    if (before !== signature(sourceFd)) throw new Error('source changed during operation');
    const result = JSON.parse(output.toString('utf8'));
    if (result.status === 'ok' && outputFd !== undefined) {
      fsyncSync(outputFd);
      closeSync(outputFd);
      outputFd = undefined;
      linkSync(stage, resolve(destination));
    }
    return result;
  } finally {
    try {
      if (sourceFd !== undefined) closeSync(sourceFd);
    } finally {
      try {
        if (outputFd !== undefined) closeSync(outputFd);
      } finally {
        if (stage !== undefined) {
          try { unlinkSync(stage); }
          catch (error) { if (error.code !== 'ENOENT') throw error; }
        }
      }
    }
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [path, operation, ...args] = process.argv.slice(2);
  if (!path || operation === '--help') {
    console.log('Usage: node tools/attachment_wasm.mjs FILE list|verify|query|extract|range [ARGS]');
    process.exitCode = path ? 0 : 2;
  } else {
    try {
      const request = { operation };
      let destination;
      switch (operation) {
        case 'list':
        case 'verify':
          if (args.length) throw new Error('unexpected arguments');
          break;
        case 'query':
          if (args.length !== 3) throw new Error('query requires TOPIC START_NS END_NS');
          [request.topic, request.start, request.end] = args;
          break;
        case 'extract':
          if (args.length !== 2) throw new Error('extract requires RECORD_OFFSET NEW_FILE');
          [request.offset, destination] = args;
          break;
        case 'range':
          if (args.length !== 3) throw new Error('range requires RECORD_OFFSET START LENGTH');
          [request.offset, request.start, request.length] = args;
          break;
        default: throw new Error('unknown operation');
      }
      const result = await attachmentRequest(path, request, { destination, build: true });
      console.log(JSON.stringify(result, null, 2));
      if (result.status !== 'ok') process.exitCode = 2;
    } catch (error) {
      console.error(error.stderr?.toString() || error.message);
      process.exitCode = 2;
    }
  }
}
