// Regenerate explicitly when accepting a change to the web visual contract.
// Usage: node tools/generate-round-fixtures.cjs [frontend repository]
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const frontend = path.resolve(process.argv[2] ?? '../endless-drawing-frontend');
const ts = require(path.join(frontend, 'node_modules/typescript'));
require.extensions['.ts'] = (module, filename) => {
  const source = fs.readFileSync(filename, 'utf8');
  module._compile(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText, filename);
};
const { tessellateStroke } = require(path.join(frontend, 'src/webgl/tessellate.ts'));
const cases = [
  { name: 'dot', points: [[0, 0]], width: 6 },
  { name: 'diagonal', points: [[10, 20], [30, 40]], width: 12 },
  { name: 'turn-and-duplicate', points: [[0, 0], [20, 0], [20, 0], [20, 30], [0, 0]], width: 6 },
  { name: 'world-edge', points: [[999999990, -999999990], [999999999, -999999980]], width: 1 },
];
const sources = ['src/webgl/tessellate.ts', 'src/brush-geometry.ts'];
const fixture = {
  version: 1,
  frontendCommit: execFileSync('git', ['-C', frontend, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
  sourceSHA256: Object.fromEntries(sources.map(file => [file,
    crypto.createHash('sha256').update(fs.readFileSync(path.join(frontend, file))).digest('hex')])),
  cases: cases.map(input => {
    const geometry = tessellateStroke({ ...input, id: '00000000-0000-4000-8000-000000000001', brush: 'round' });
    return { ...input, triangles: Array.from(geometry.triangles), circles: Array.from(geometry.circles) };
  }),
};
const output = path.resolve(__dirname, '../Endless DrawingTests/Fixtures/round-geometry.json');
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, JSON.stringify(fixture, null, 2) + '\n');
console.log(`Wrote ${fixture.cases.length} cases from ${fixture.frontendCommit}`);
