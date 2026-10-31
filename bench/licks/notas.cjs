// As notas da primeira pista de cada Guitar Pro com o áudio dentro (os licks de "Blues Licks" no HD externo, o
// reference.gp), no tempo do áudio: pelos pontos de sincronia do Guitar Pro 8 (o compasso, o instante e o andamento
// "modificado", o do áudio; o alphaTab não guarda esse andamento, então ele vem do score.gpif), um ponto por semínima,
// em linha reta entre dois pontos e no andamento do último depois dele. O MP3 de dentro vai para a pasta do áudio.
// node bench/licks/notas.cjs <saída.json> <pasta do áudio> <arquivo.gp ou pasta>… (o refazer.sh chama)
"use strict";
const fs = require("fs"), path = require("path");
const repo = path.join(__dirname, "..", "..");
const a = require(path.join(repo, "web/vendor/alphatab/alphaTab.js"));
const core = require(path.join(repo, "web/score-core.js"));
const [out, audio, ...inputs] = process.argv.slice(2);
if (!out || !audio || !inputs.length) {
  console.error("uso: node bench/licks/notas.cjs <saída.json> <pasta do áudio> <arquivo.gp ou pasta>…");
  process.exit(1);
}
const files = inputs.flatMap((p) => fs.statSync(p).isDirectory()
  ? fs.readdirSync(p).filter((f) => f.endsWith(".gp")).sort().map((f) => path.join(p, f)) : [p]);
fs.mkdirSync(audio, { recursive: true });
// O score.gpif de dentro do zip.
const gpif = (file) => require("child_process").execFileSync("unzip", ["-p", file, "Content/score.gpif"]).toString("utf8");
const songs = [];
for (const file of files) {
  const name = path.basename(file).replace(/\.gp$/, "");
  const score = a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(file)), new a.Settings());
  if (!score.backingTrack || !score.backingTrack.rawAudioFile) {
    console.error(name, "sem áudio dentro: fica de fora");
    continue;
  }
  const mp3 = path.join(audio, name + ".mp3");
  fs.writeFileSync(mp3, Buffer.from(score.backingTrack.rawAudioFile));
  const sync = [...gpif(file).matchAll(/<BarIndex>(\d+)<\/BarIndex>[\s\S]*?<ModifiedTempo>([\d.]+)<\/ModifiedTempo>[\s\S]*?<FrameOffset>(-?\d+)<\/FrameOffset>/g)]
    .map((m) => ({ tick: score.masterBars[+m[1]].start, tempo: +m[2], frame: +m[3] }));
  if (!sync.length) {
    console.error(name, "sem pontos de sincronia: fica de fora");
    continue;
  }
  const rate = 44100;
  const end = score.masterBars.at(-1).start + score.masterBars.at(-1).calculateDuration();
  const anchors = sync.map((p) => ({ tick: p.tick, seconds: p.frame / rate, tempo: p.tempo }));
  const seconds = (tick) => {
    let k = 0;
    while (k + 1 < anchors.length && anchors[k + 1].tick <= tick) k++;
    const p = anchors[k], q = anchors[k + 1];
    if (q && tick <= q.tick) return p.seconds + (q.seconds - p.seconds) * (tick - p.tick) / (q.tick - p.tick);
    return p.seconds + (tick - p.tick) / 960 * 60 / p.tempo;
  };
  const points = [];
  for (let t = 0; t <= end + 960; t += 960) points.push({ tick: t, seconds: seconds(t), kind: "detected" });
  const raw = core.trackNotes(score)[0];
  const notes = raw.map((n) => ({ tick: n[0], duration: n[1], pitch: n[2], string: n[3], fret: n[4], vibrato: n[5],
    trill: n[6] || null, approached: (n[7] & 1) > 0, slidesOut: (n[7] & 2) > 0, bend: n.slice(8),
    start: core.tickToSeconds(points, n[0]), end: core.tickToSeconds(points, n[0] + n[1]) }));
  for (const n of notes) {
    n.others = notes.filter((o) => o !== n && o.tick === n.tick).map((o) => o.pitch);
    const next = notes.find((o) => o.string === n.string && o.tick >= n.tick + n.duration - 1);
    n.next = next ? { pitch: next.pitch, gap: next.tick - (n.tick + n.duration) } : null;
  }
  songs.push({ name, mp3, sync, tracks: [{ index: 0, name: score.tracks[0].name, notes }] });
  console.error(name, "notas", notes.length, "com bend", notes.filter((n) => n.bend.length).length);
}
fs.writeFileSync(out, JSON.stringify({ songs }));
