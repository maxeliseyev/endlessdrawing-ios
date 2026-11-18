// Explicit acceptance of the current web visual contract; ordinary native tests never regenerate.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const frontend = path.resolve(process.argv[2] ?? '../endless-drawing-frontend');
const ts = require(path.join(frontend, 'node_modules/typescript'));
require.extensions['.ts'] = (module, filename) => module._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText, filename);
const { tessellateStroke } = require(path.join(frontend, 'src/webgl/tessellate.ts'));
const id = '87a122fa-7537-4b88-9b77-b45d24a29714';
const cases = [];
for (const brush of ['square', 'chisel', 'spray']) {
  for (const sample of [
    { name: 'dot', points: [[0, 0]], width: 6 },
    { name: 'turn', points: [[0, 0], [20, 0], [20, 0], [20, 30], [0, 0]], width: 12 },
    { name: 'world-edge', points: [[999999990, -999999990], [999999999, -999999980]], width: 1 },
    { name: 'wide', points: [[-30, 10], [30, 20]], width: 64 },
  ]) {
    const input = { ...sample, name: `${brush}-${sample.name}`, brush, id };
    const geometry = tessellateStroke(input);
    cases.push({ ...input, triangles: Array.from(geometry.triangles), circles: Array.from(geometry.circles) });
  }
}
const sources = ['src/webgl/tessellate.ts', 'src/brush-geometry.ts'];
fs.writeFileSync(path.resolve(__dirname, '../Endless DrawingTests/Fixtures/brush-geometry.json'), JSON.stringify({
  version: 1,
  frontendCommit: execFileSync('git', ['-C', frontend, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
  sourceSHA256: Object.fromEntries(sources.map(file => [file, crypto.createHash('sha256').update(fs.readFileSync(path.join(frontend, file))).digest('hex')])),
  cases,
}, null, 2) + '\n');
console.log(`Wrote ${cases.length} brush fixtures (spray maximum diameter 1).`);
