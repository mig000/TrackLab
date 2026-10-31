// As notas de cada item do GOAT pelo alphaTab do TrackLab (core.trackNotes, como o app), cada uma em cada vez que
// toca (repetições abertas pelo tickLookup do MidiFileGenerator do alphaTab) com o instante no tempo do Guitar Pro
// (os andamentos do arquivo), para casar com o MIDI exportado pelo Guitar Pro (item_N.mid).
// node bench/goat/notas.cjs <repo TrackLab> <pasta GOAT/data> <saída.json> [item_0 item_1 ...] (o refazer.sh chama)
"use strict";
const fs = require("fs"), path = require("path");
const [repo, data, out, ...only] = process.argv.slice(2);
const a = require(path.join(repo, "web/vendor/alphatab/alphaTab.js"));
const core = require(path.join(repo, "web/score-core.js"));

const items = only.length ? only : fs.readdirSync(data).filter((d) => /^item_\d+$/.test(d))
  .sort((x, y) => +x.slice(5) - +y.slice(5));
const result = [];
for (const item of items) {
  const file = path.join(data, item, item + ".gp");
  let score;
  try {
    score = a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(file)), new a.Settings());
  } catch (e) {
    result.push({ item, error: String(e) });
    console.error(item, "erro", e.message);
    continue;
  }
  // As vezes que cada compasso toca (repetições, casas 1 e 2), pelo gerador de MIDI do alphaTab.
  const midi = new a.midi.MidiFile();
  const settings = new a.Settings();
  settings.notation.extendBendArrowsOnTiedNotes = false;
  const generator = new a.midi.MidiFileGenerator(score, settings, new a.midi.AlphaSynthMidiFileHandler(midi, true));
  generator.generate();
  const lookups = generator.tickLookup.masterBars;
  // Segundos de cada vez: os andamentos de dentro de cada compasso tocado.
  let seconds = 0;
  const plays = []; // {bar, start (tique tocado), end, seconds, tempos:[{tick, tempo}]}
  for (const m of lookups) {
    const tempos = m.tempoChanges.map((c) => ({ tick: c.tick, tempo: c.tempo }));
    plays.push({ bar: m.masterBar.index, start: m.start, end: m.end, seconds, tempos });
    for (let i = 0; i < tempos.length; i++) {
      const from = Math.max(m.start, tempos[i].tick);
      const to = i + 1 < tempos.length ? tempos[i + 1].tick : m.end;
      seconds += Math.max(0, to - from) / 960 * 60 / tempos[i].tempo;
    }
  }
  const secondsAt = (play, tick) => {
    // tick tocado dentro (ou depois) de `play`, seguindo pelos compassos tocados seguintes.
    let k = plays.indexOf(play);
    while (k + 1 < plays.length && tick >= plays[k + 1].start && plays[k + 1].start >= play.start) k++;
    const p = plays[k];
    let s = p.seconds;
    for (let i = 0; i < p.tempos.length; i++) {
      const from = Math.max(p.start, p.tempos[i].tick);
      const to = Math.min(tick, i + 1 < p.tempos.length ? p.tempos[i + 1].tick : Infinity);
      if (to > from) s += (to - from) / 960 * 60 / p.tempos[i].tempo;
    }
    return s;
  };
  const byBar = new Map();
  for (const p of plays) {
    if (!byBar.has(p.bar)) byBar.set(p.bar, []);
    byBar.get(p.bar).push(p);
  }
  const lists = core.trackNotes(score);
  const tracks = [];
  for (const [index, raw] of lists.entries()) {
    const track = score.tracks[index];
    const staff = track.staves[0];
    const info = { index, name: track.name, percussion: track.staves.some((s) => s.isPercussion),
      tuning: staff.tuning ? [...staff.tuning] : [], capo: staff.capo, transpose: staff.transpositionPitch,
      displayTranspose: staff.displayTranspositionPitch, program: track.playbackInfo.program,
      mute: track.playbackInfo.isMute, notes: [] };
    for (const n of raw) {
      const tick = n[0], duration = n[1];
      const mb = score.masterBars.find((m, i) => m.start <= tick && (i + 1 === score.masterBars.length || score.masterBars[i + 1].start > tick));
      const note = { tick, duration, pitch: n[2], string: n[3], fret: n[4], vibrato: n[5], trill: n[6] || null,
        approached: (n[7] & 1) > 0, slidesOut: (n[7] & 2) > 0, bend: n.slice(8), bar: mb.index + 1, plays: [] };
      for (const p of byBar.get(mb.index) || []) {
        const t0 = p.start + (tick - mb.start), t1 = t0 + duration;
        note.plays.push([+secondsAt(p, t0).toFixed(5), +secondsAt(p, t1).toFixed(5)]);
      }
      info.notes.push(note);
    }
    // others e next como no bend-curves.cjs (na partitura escrita).
    for (const n of info.notes) {
      n.others = info.notes.filter((o) => o !== n && o.tick === n.tick).map((o) => o.pitch);
      const next = info.notes.find((o) => o.string === n.string && o.tick >= n.tick + n.duration - 1);
      n.next = next ? { pitch: next.pitch, gap: next.tick - (n.tick + n.duration) } : null;
    }
    tracks.push(info);
  }
  const written = score.masterBars.length;
  result.push({ item, title: score.title, artist: score.artist, bars: written, played: plays.length,
    repeats: plays.length !== written, tempo: score.tempo, length: seconds, tracks,
    barStarts: score.masterBars.map((m) => m.start) });
  console.error(item, score.tracks.length, "pistas", written, "compassos,", plays.length, "tocados",
    tracks.map((t) => `${t.name}:${t.notes.length}`).join(" "));
}
fs.writeFileSync(out, JSON.stringify(result));
