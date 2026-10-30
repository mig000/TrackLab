// node web/tools/gp-synth.cjs <partitura.gp> <soundfont.sf2> <mapa.json> <pasta> <taxa>: a TAB sintetizada sem
// nada instalado além do node, pelo sintetizador do próprio alphaTab (TinySoundFont, o mesmo do player do alphaTab).
// Para cada pista com notas: o MIDI dela (gerado pelo alphaTab, com as articulações), o andamento do Guitar Pro trocado
// pelo do mapa de tempo (um evento de andamento por ponto, a partir do tique 0) e o áudio estéreo em float32
// intercalado em <pasta>/t<pista>.f32, na taxa pedida, começando no tique 0. Escreve no stdout, em JSON, as pistas
// sintetizadas. O motor (media/synth.py) põe cada uma no tempo do áudio do vídeo.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const alphaTab = require(path.join(__dirname, "..", "vendor", "alphatab", "alphaTab.js"));

const [source, fontPath, pointsPath, folder, rateText] = process.argv.slice(2);
if (!source || !fontPath || !pointsPath || !folder) {
  console.error("uso: node gp-synth.cjs <partitura.gp> <soundfont.sf2> <mapa.json> <pasta> [taxa]");
  process.exit(2);
}
const rate = Number(rateText) || 44100;
const QUARTER = 960;
const RENDER_MS = 10000;

const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(source)), new alphaTab.Settings());
for (const track of score.tracks) {
  track.playbackInfo.isMute = false;
  track.playbackInfo.isSolo = false;
}
const whole = new alphaTab.midi.MidiFile();
whole.format = alphaTab.midi.MidiFileFormat.MultiTrack;
new alphaTab.midi.MidiFileGenerator(score, new alphaTab.Settings(), new alphaTab.midi.AlphaSynthMidiFileHandler(whole, true))
  .generate();

// O andamento do mapa: em cada ponto, o do trecho até o ponto seguinte; o primeiro trecho vale desde o tique 0.
const points = JSON.parse(fs.readFileSync(pointsPath, "utf8"))
  .map((p) => [Number(p.tick), Number(p.seconds)])
  .sort((a, b) => a[0] - b[0]);
const tempos = [];
for (let i = 0; i + 1 < points.length; i++) {
  const [t0, s0] = points[i];
  const [t1, s1] = points[i + 1];
  if (t1 > t0 && s1 > s0) {
    tempos.push([tempos.length ? Math.round(t0 * (whole.division / QUARTER)) : 0, ((s1 - s0) / (t1 - t0)) * QUARTER * 1e6]);
  }
}
if (!tempos.length) {
  console.error("o mapa de tempo não cresce");
  process.exit(3);
}
const soundFont = new Uint8Array(fs.readFileSync(fontPath));
const done = [];
score.tracks.forEach((track, index) => {
  const events = (whole.tracks[index] ? whole.tracks[index].events : []).filter(
    (e) => !(e instanceof alphaTab.midi.TempoChangeEvent));
  if (!events.some((e) => e instanceof alphaTab.midi.NoteOnEvent || e.type === 0x90)) {
    return;
  }
  // Uma trilha só (formato 0): o `events` do MidiFile do alphaTab só soma várias trilhas com erro.
  const midi = new alphaTab.midi.MidiFile();
  midi.format = alphaTab.midi.MidiFileFormat.SingleTrack;
  midi.division = whole.division;
  const ordered = tempos.map(([tick, micros]) => new alphaTab.midi.TempoChangeEvent(tick, micros)).concat(events);
  ordered.sort((a, b) => a.tick - b.tick);
  for (const event of ordered) {
    event.track = 0;
    midi.addEvent(event);
  }
  const options = new alphaTab.synth.AudioExportOptions();
  options.soundFonts = [soundFont];
  options.sampleRate = rate;
  options.masterVolume = 1;
  options.useSyncPoints = false;
  // exportAudio só usa o sintetizador do próprio objeto quando não recebe SoundFont: aqui nenhum é preciso.
  const exporter = alphaTab.synth.AlphaSynth.prototype.exportAudio.call({}, options, midi, [], new Map());
  const target = path.join(folder, `t${index}.f32`);
  const out = fs.openSync(target, "w");
  let frames = 0;
  for (let chunk = exporter.render(RENDER_MS); chunk; chunk = exporter.render(RENDER_MS)) {
    fs.writeSync(out, Buffer.from(chunk.samples.buffer, chunk.samples.byteOffset, chunk.samples.byteLength));
    frames += chunk.samples.length / 2;
  }
  fs.closeSync(out);
  done.push({
    index,
    name: track.name || `Faixa ${index + 1}`,
    program: track.playbackInfo.program,
    percussion: track.staves.some((staff) => staff.isPercussion),
    file: path.basename(target),
    frames,
  });
});
process.stdout.write(JSON.stringify({ rate, tracks: done }));
