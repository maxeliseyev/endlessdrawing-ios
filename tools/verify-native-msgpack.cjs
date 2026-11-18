// Independently read Swift actual-output artifacts with the frontend's bounded production codec.
// Usage: node tools/verify-native-msgpack.cjs <simulator tmp/ws-v2-swift-interop> [frontend repository]
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { isDeepStrictEqual } = require('node:util');
if (!process.argv[2]) throw new Error('Specify the Swift test artifact directory');
const output = path.resolve(process.argv[2]);
const frontend = path.resolve(process.argv[3] ?? '../endless-drawing-frontend');
const ts = require(path.join(frontend, 'node_modules/typescript'));
require.extensions['.ts'] = (module, filename) => {
  module._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText, filename);
};
const { decodeMessagePack } = require(path.join(frontend, 'src/transport/msgpack.ts'));
const fixtures = path.resolve(__dirname, '../Endless DrawingTests/Fixtures/ws-v2');
const manifest = JSON.parse(fs.readFileSync(path.join(fixtures, 'sha256.json'), 'utf8'));
for (const [file, expected] of Object.entries(manifest)) {
  const actual = crypto.createHash('sha256').update(fs.readFileSync(path.join(fixtures, file))).digest('hex');
  assert.equal(actual, expected, `Pinned fixture hash: ${file}`);
}
const corpus = JSON.parse(fs.readFileSync(path.join(fixtures, 'corpus.json'), 'utf8'));
function normalize(value) {
  if (Array.isArray(value)) return value.map(normalize);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, normalize(child)]));
  return Object.is(value, -0) ? 0 : value;
}
let bytes = 0;
for (const sample of corpus) {
  const payload = fs.readFileSync(path.join(output, `${sample.name}.swift.msgpack`));
  const decoded = decodeMessagePack(new Uint8Array(payload));
  if (!isDeepStrictEqual(normalize(decoded), normalize(sample.value))) {
    throw new Error(`Swift → frontend semantic mismatch: ${sample.name}`); // never dump decoded bodies
  }
  bytes += payload.byteLength;
}
console.log(`PASS: ${corpus.length} Swift messages decoded by frontend production codec; ${bytes} application bytes. No payloads logged.`);
