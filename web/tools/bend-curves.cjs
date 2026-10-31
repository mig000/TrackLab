// As notas das guitarras das músicas do repertório com a curva do som de cada uma (o motor, POST songs/{id}/pitch),
// como o app pede: a nota inteira com as ligadas (trackNotes), as outras do acorde e a faixa onde a pista soa.
// node web/tools/bend-curves.cjs <url do motor> <saída.json> (a medição: TRACKLAB_BEND_BENCH=<saída.json> mac/test.sh
// --filter medicaoDosBends). Lê o repertório de ~/TrackLab/Repertorio, menos a música de teste; ~10 min no iMac.
const fs = require("fs"), path = require("path");
const a = require("../vendor/alphatab/alphaTab.js");
const core = require("../score-core.js");
const [url, out] = process.argv.slice(2);
if (!url || !out) {
  console.error("uso: node web/tools/bend-curves.cjs <url do motor, http://127.0.0.1:porta> <saída.json>");
  process.exit(1);
}
const root = path.join(process.env.HOME, "TrackLab/Repertorio");
(async () => {
  const songs = [];
  for (const folder of fs.readdirSync(root).filter((d) => d.endsWith(".tracklab") && !d.includes("notacao"))) {
    const m = JSON.parse(fs.readFileSync(path.join(root, folder, "manifest.json")));
    const score = a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(path.join(root, folder, m.score.file))), new a.Settings());
    const points = JSON.parse(fs.readFileSync(path.join(root, folder, m.tempoMap.file))).points;
    const files = (m.stems[m.activeStems] || {}).files || {};
    const lists = core.trackNotes(score);
    const song = { id: m.id, name: folder, tracks: [] };
    for (const [index, raw] of lists.entries()) {
      const name = score.tracks[index].name.toLowerCase();
      if (!raw.length || /drum|bateria|percuss|vocal|voz|voice|vox|bass|baixo|piano|keys|keyboard|organ|synth/.test(name)) continue;
      const stem = /rhythm|ritmo|base/.test(name) && files.rhythm ? "rhythm" : "guitar";
      if (!files[stem]) continue;
      const notes = raw.map((n) => ({ tick: n[0], duration: n[1], pitch: n[2], string: n[3], fret: n[4], vibrato: n[5],
        trill: n[6] || null, approached: (n[7] & 1) > 0, slidesOut: (n[7] & 2) > 0, bend: n.slice(8), start: core.tickToSeconds(points, n[0]), end: core.tickToSeconds(points, n[0] + n[1]) }));
      for (const n of notes) {
        n.others = notes.filter((o) => o !== n && o.tick === n.tick).map((o) => o.pitch);
        const next = notes.find((o) => o.string === n.string && o.tick >= n.tick + n.duration - 1);
        n.next = next ? { pitch: next.pitch, gap: next.tick - (n.tick + n.duration) } : null;
        n.key = `${index}:${n.tick}:${n.string}`;
      }
      for (let i = 0; i < notes.length; i += 200) {
        const batch = notes.slice(i, i + 200).filter((n) => n.end > n.start && n.end - n.start <= 8);
        const body = { stem, notes: batch.map((n) => ({ key: n.key, start: n.start, end: n.end, pitch: n.pitch,
          others: n.others.length ? n.others : undefined })) };
        const answer = await (await fetch(`${url}/api/songs/${m.id}/pitch`, { method: "POST",
          headers: { "content-type": "application/json" }, body: JSON.stringify(body) })).json();
        for (const n of batch) n.curve = answer.curves[n.key] || null;
      }
      song.tracks.push({ index, name: score.tracks[index].name, stem, notes: notes.filter((n) => n.curve) });
      console.log(folder, index, score.tracks[index].name.slice(0, 40), stem, notes.length, "notas,",
        notes.filter((n) => n.bend.length).length, "com bend escrito");
    }
    songs.push(song);
  }
  fs.writeFileSync(out, JSON.stringify({ songs }));
})();
