// As notas de cada pista e os acordes escritos de um Guitar Pro, no formato que a página manda ao app, para medir a
// barra de acordes fora do app: node web/tools/chord-notes.cjs <arquivo.gp> <saída.json>, e depois
// TRACKLAB_CHORDS_NOTES=<saída.json> mac/test.sh --filter acordesDeUmaMusica.
const fs = require("node:fs");
const alphaTab = require("../vendor/alphatab/alphaTab.js");
const core = require("../score-core.js");

const [file, out] = process.argv.slice(2);
if (!file || !out) {
  console.error("uso: node web/tools/chord-notes.cjs <arquivo.gp> <saída.json>");
  process.exit(2);
}
const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(file)), new alphaTab.Settings());
const masters = score.masterBars;
const last = masters[masters.length - 1];
fs.writeFileSync(out, JSON.stringify({
  tracks: score.tracks.map((track, index) => track.name || "Faixa " + (index + 1)),
  notes: core.trackNotes(score),
  barTicks: masters.map((m) => m.start).concat([last.start + last.calculateDuration()]),
  chords: core.writtenChords(score),
}));
console.log(`${score.tracks.length} pistas, ${masters.length} compassos`);
