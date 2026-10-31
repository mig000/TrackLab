// node web/tests/check-edit.cjs: a edição da TAB (score-edit.js) no alphaTab do projeto, sobre o Guitar Pro de
// tests/fixtures: cada articulação liga, sobrevive à cópia da partitura (o finish) e à gravação em Guitar Pro 7.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const alphaTab = require("../vendor/alphatab/alphaTab.js");
const edit = require("../score-edit.js");

let passed = 0;
function test(name, body) {
  body();
  passed += 1;
  console.log("ok", name);
}

const bytes = new Uint8Array(fs.readFileSync(path.join(__dirname, "fixtures", "quatro-por-quatro.gp")));
const load = () => alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes, new alphaTab.Settings());
const first = (score) => edit.notesOf(score.tracks[0].staves[0])[0];
const reread = (score) => alphaTab.importer.ScoreLoader.loadScoreFromBytes(edit.exportGp(alphaTab, score), new alphaTab.Settings());

test("cada articulação da nota liga, passa pelo finish e pelo Guitar Pro, e desliga", () => {
  const keys = ["slide-out-up", "slide-in-below", "vibrato", "wide-vibrato", "palm-mute", "let-ring", "ghost",
    "staccato", "accent", "heavy-accent", "harmonic-natural", "harmonic-pinch", "bend-full", "bend-half",
    "bend-release", "prebend", "pick-down", "pick-up", "tap", "dead"];
  for (const key of keys) {
    let score = load();
    const note = first(score);
    const where = edit.pathOf(note);
    assert.ok(edit.toggle(alphaTab, note, key), key);
    score = edit.refinish(alphaTab, score);
    assert.ok(edit.techniquesOf(alphaTab, edit.resolve(score, where)).includes(key), `${key} depois do finish`);
    const again = reread(score);
    assert.ok(edit.techniquesOf(alphaTab, edit.resolve(again, where)).includes(key), `${key} no Guitar Pro`);
    edit.toggle(alphaTab, edit.resolve(score, where), key);
    assert.ok(!edit.techniquesOf(alphaTab, edit.resolve(score, where)).includes(key), `${key} desligada`);
  }
});

test("no mesmo grupo, ligar troca; nota morta não tem bend nem vibrato", () => {
  const score = load();
  const note = first(score);
  edit.toggle(alphaTab, note, "vibrato");
  edit.toggle(alphaTab, note, "wide-vibrato");
  assert.deepEqual(edit.techniquesOf(alphaTab, note).filter((k) => k.includes("vibrato")), ["wide-vibrato"]);
  edit.toggle(alphaTab, note, "bend-full");
  edit.toggle(alphaTab, note, "dead");
  const on = edit.techniquesOf(alphaTab, note);
  assert.ok(on.includes("dead") && !on.includes("bend-full") && !on.includes("wide-vibrato"));
});

test("ligado e slide entre notas ficam presos à nota seguinte da corda", () => {
  let score = load();
  const notes = edit.notesOf(score.tracks[0].staves[0]);
  // Duas notas seguidas na mesma corda.
  const index = notes.findIndex((n, i) => notes[i + 1] && notes[i + 1].string === n.string);
  assert.ok(index >= 0, "a fixture tem duas notas seguidas na mesma corda");
  const where = edit.pathOf(notes[index]);
  edit.toggle(alphaTab, notes[index], "hammer");
  score = edit.refinish(alphaTab, score);
  const origin = edit.resolve(score, where);
  assert.ok(origin.isHammerPullOrigin && origin.hammerPullDestination, "o finish liga o ligado à nota seguinte");
  edit.toggle(alphaTab, origin, "slide-legato");
  score = edit.refinish(alphaTab, score);
  assert.ok(edit.resolve(score, where).slideTarget, "o finish liga o slide à nota seguinte");
});

test("desligar ou trocar o slide, ou apagar a nota de onde ele sai, não solta a outra ponta", () => {
  // O alphaTab lia a cópia procurando a origem do slide pelo id e quebrava: a edição parava de desenhar e gravar.
  const pair = (score) => {
    const notes = edit.notesOf(score.tracks[0].staves[0]);
    const index = notes.findIndex((n, i) => notes[i + 1] && notes[i + 1].string === n.string);
    return [notes[index], notes[index + 1]];
  };
  for (const link of ["slide-legato", "slide-shift", "hammer"]) {
    for (const then of ["off", "slide-out-up", "slide-in-below", "remove"]) {
      let score = load();
      const [from] = pair(score);
      const where = edit.pathOf(from);
      edit.toggle(alphaTab, from, link);
      score = edit.refinish(alphaTab, score);
      const origin = edit.resolve(score, where);
      assert.ok(origin.slideTarget || origin.hammerPullDestination, `${link} ligado à seguinte`);
      if (then === "off") edit.toggle(alphaTab, origin, link);
      else if (then === "remove") edit.remove(origin);
      else edit.toggle(alphaTab, origin, then);
      score = edit.refinish(alphaTab, score);
      reread(score);
      const on = then === "remove" ? [] : edit.techniquesOf(alphaTab, edit.resolve(score, where));
      // Sai ↗ troca um slide (o mesmo grupo); Entra e o ligado convivem com ele.
      const replaced = then === "off" || (then === "slide-out-up" && link !== "hammer");
      assert.equal(on.includes(link), then !== "remove" && !replaced, `${link} → ${then}`);
    }
  }
  // A ligadura: apagada a nota de onde vem, a seguinte deixa de ser ligada (ou liga na anterior da corda).
  let score = load();
  const [from, to] = pair(score);
  const where = edit.pathOf(to);
  to.fret = from.fret;
  to.isTieDestination = true;
  score = edit.refinish(alphaTab, score);
  assert.ok(edit.resolve(score, where).tieOrigin, "a ligadura liga");
  edit.remove(edit.resolve(score, where).tieOrigin);
  score = edit.refinish(alphaTab, score);
  reread(score);
});

test("casa, corda (mesma altura), meio tom e apagar", () => {
  const score = load();
  const note = first(score);
  const pitch = note.realValue;
  assert.ok(edit.setFret(note, 7) && note.fret === 7 && !edit.setFret(note, 25));
  const at7 = note.realValue;
  const before = edit.tabString(note);
  const moved = edit.moveString(note, -1) || edit.moveString(note, 1);
  assert.ok(moved && edit.tabString(note) !== before && note.realValue === at7, "outra corda, mesma altura");
  assert.ok(edit.transpose(note, 1) && note.realValue === at7 + 1);
  assert.notEqual(pitch, undefined);
  const beat = note.beat;
  const count = beat.notes.length;
  assert.ok(edit.remove(note) && beat.notes.length === count - 1);
});

test("navegar pelas notas e achar a nota de novo depois da cópia", () => {
  let score = load();
  const a = first(score);
  const b = edit.neighbor(a, 1);
  assert.ok(b && edit.neighbor(b, -1) === a && edit.neighbor(a, -1) === null);
  const where = edit.pathOf(b);
  score = edit.refinish(alphaTab, score);
  const found = edit.resolve(score, where);
  assert.equal(found.fret, b.fret);
  const described = edit.describe(alphaTab, found);
  assert.equal(described.string, edit.tabString(b));
  // Para a coluna de edição: a figura e a casa da mesma altura em cada corda (a da nota é a casa dela).
  assert.equal(described.strings.length, found.beat.voice.bar.staff.tuning.length);
  assert.equal(described.strings[described.string - 1], found.fret);
  assert.ok(typeof described.figure === "string");
  const tuning = found.beat.voice.bar.staff.tuning;
  described.strings.forEach((fret, i) => {
    if (fret !== null) assert.equal(tuning[i] + fret, tuning[described.string - 1] + found.fret);
  });
});


test("o encaixe no som da Fita: altura, bend que volta e vibrato, e a nota achada pelo tique e pela corda", () => {
  let score = load();
  const note = first(score);
  const where = edit.pathOf(note);
  const string = edit.tabString(note);
  assert.equal(edit.findNote(score, 0, note.beat.absolutePlaybackStart, string), note);
  const pitch = note.realValue + 1;
  assert.ok(edit.fit(alphaTab, note, { pitch, bend: [[12, 0], [30, 4], [44, 4], [50, 0]], vibrato: true }));
  score = edit.refinish(alphaTab, score);
  const again = edit.resolve(reread(score), where);
  assert.equal(again.realValue, pitch);
  const on = edit.techniquesOf(alphaTab, again);
  assert.ok(on.includes("bend-release") && on.includes("vibrato"), on.join(","));
  assert.deepEqual(again.bendPoints.map((p) => [Math.round(p.offset), p.value]), [[12, 0], [30, 4], [44, 4], [50, 0]]);
  // O bend que fica: o GP7 guarda a saída e a chegada.
  let held = load();
  const plain = first(held);
  assert.ok(edit.fit(alphaTab, plain, { pitch: plain.realValue, bend: [[12, 0], [30, 4]], vibrato: false }));
  held = reread(edit.refinish(alphaTab, held));
  assert.deepEqual(edit.resolve(held, where).bendPoints.map((p) => [Math.round(p.offset), p.value]), [[12, 0], [30, 4]]);
  // O mesmo de novo não muda nada; sem bend nem vibrato, os dois saem.
  assert.ok(!edit.fit(alphaTab, edit.resolve(score, where), { pitch, bend: [[12, 0], [30, 4], [44, 4], [50, 0]], vibrato: true }));
  assert.ok(edit.fit(alphaTab, edit.resolve(score, where), { pitch, bend: null, vibrato: false }));
  assert.deepEqual(edit.techniquesOf(alphaTab, edit.resolve(score, where)).filter((k) => k.includes("bend") || k.includes("vibrato")), []);
  // O trinado: a outra nota um tom acima, em fusas, sobrevive ao Guitar Pro (a velocidade numa XProperty da nota, como
  // o Guitar Pro 8 grava); o mesmo de novo não muda; sem `trill`, sai.
  let trilled = load();
  const base = first(trilled);
  assert.ok(edit.fit(alphaTab, base, { pitch: base.realValue, bend: null, vibrato: false, trill: base.realValue + 2, trillSpeed: 32 }));
  trilled = reread(edit.refinish(alphaTab, trilled));
  const back = edit.resolve(trilled, where);
  assert.ok(back.isTrill && back.trillFret === back.fret + 2 && back.trillSpeed === alphaTab.model.Duration.ThirtySecond);
  assert.ok(!edit.fit(alphaTab, back, { pitch: back.realValue, bend: null, vibrato: false, trill: back.realValue + 2, trillSpeed: 32 }));
  assert.ok(edit.fit(alphaTab, back, { pitch: back.realValue, bend: null, vibrato: false }) && !back.isTrill);
});

// A soma das figuras de cada compasso da voz 1 bate com a fórmula de compasso (nada sobra nem falta).
function barsAreWhole(score) {
  for (const bar of score.tracks[0].staves[0].bars) {
    const sum = bar.voices[0].beats.reduce((total, b) => total + b.playbackDuration, 0);
    assert.equal(Math.round(sum), bar.masterBar.calculateDuration(), `compasso ${bar.index + 1}`);
  }
}
const at = (score, tick) => edit.notesOf(score.tracks[0].staves[0]).find((n) => Math.abs(n.beat.absolutePlaybackStart - tick) < 1);

test("adiantar uma nota: a anterior encurta, o espaço vira pausa, o compasso fecha", () => {
  let score = load();
  const note = at(score, 960);
  assert.equal(edit.nudge(alphaTab, note, -1, 240), true);
  score = reread(edit.refinish(alphaTab, score));
  barsAreWhole(score);
  const moved = at(score, 720);
  assert.ok(moved, "a nota começa uma semicolcheia antes");
  assert.equal(moved.beat.playbackDuration, 960, "a duração fica");
  assert.equal(at(score, 0).beat.playbackDuration, 720, "a anterior encurtou");
  // A primeira do compasso também anda para depois: uma pausa entra antes dela.
  let again = load();
  assert.equal(edit.nudge(alphaTab, at(again, 0), 1, 240), true);
  again = reread(edit.refinish(alphaTab, again));
  barsAreWhole(again);
  assert.ok(at(again, 240) && again.tracks[0].staves[0].bars[0].voices[0].beats[0].isRest);
});

test("atravessar a barra de compasso: a nota vira duas ligadas", () => {
  let score = load();
  // Abre espaço: a primeira nota do compasso 2 começa uma colcheia depois.
  const second = at(score, 3840);
  const where = edit.span(second);
  assert.equal(edit.retime(alphaTab, second, where.start + 480, where.end), true);
  score = edit.refinish(alphaTab, score);
  // A última do compasso 1 passa da barra até lá.
  const last = at(score, 2880);
  assert.equal(edit.retime(alphaTab, last, 2880, 3840 + 480), true);
  score = reread(edit.refinish(alphaTab, score));
  barsAreWhole(score);
  const head = at(score, 2880);
  const tied = score.tracks[0].staves[0].bars[1].voices[0].beats[0].notes[0];
  assert.ok(tied && tied.isTieDestination && tied.fret === head.fret, "a continuação no compasso 2 é ligada");
  assert.deepEqual(edit.span(head), { start: 2880, end: 4320 });
});

test("tercinas quando a grade pede", () => {
  let score = load();
  const note = at(score, 0);
  assert.equal(edit.retime(alphaTab, note, 0, 320), true);
  score = reread(edit.refinish(alphaTab, score));
  barsAreWhole(score);
  const beat = at(score, 0).beat;
  assert.equal(beat.tupletNumerator, 3);
  assert.equal(edit.figureName(320), "tercina de colcheias");
});

test("a figura da nota: mais curta deixa pausa, pontuada e tercina; mais longa não passa da seguinte", () => {
  let score = load();
  // A primeira semínima vira colcheia: a nota seguinte fica no lugar e o espaço é pausa.
  assert.deepEqual(edit.rhythmOf(960), { base: 960, dots: 0, triplet: false });
  assert.equal(edit.setLength(alphaTab, at(score, 0), 480), true);
  score = reread(edit.refinish(alphaTab, score));
  barsAreWhole(score);
  assert.equal(at(score, 0).beat.playbackDuration, 480);
  assert.ok(at(score, 960), "a seguinte não andou");
  assert.ok(score.tracks[0].staves[0].bars[0].voices[0].beats[1].isRest);
  const described = edit.describe(alphaTab, at(score, 0));
  assert.equal(described.length, 480);
  assert.equal(described.figure, "colcheia");
  assert.equal(described.base, 480);
  // Colcheia pontuada e tercina de colcheias.
  assert.equal(edit.setLength(alphaTab, at(score, 0), 720), true);
  score = reread(edit.refinish(alphaTab, score));
  barsAreWhole(score);
  assert.deepEqual(edit.rhythmOf(edit.span(at(score, 0)).end), { base: 480, dots: 1, triplet: false });
  assert.equal(edit.setLength(alphaTab, at(score, 0), 320), true);
  score = reread(edit.refinish(alphaTab, score));
  barsAreWhole(score);
  assert.equal(edit.describe(alphaTab, at(score, 0)).triplet, true);
  // Mais longa que o espaço até a seguinte: não.
  assert.equal(edit.setLength(alphaTab, at(score, 0), 1920), "next");
});

test("a nota vira pausa: a batida sai e as outras ficam no lugar", () => {
  let score = load();
  assert.equal(edit.toRest(alphaTab, at(score, 960)), true);
  score = reread(edit.refinish(alphaTab, score));
  barsAreWhole(score);
  assert.equal(at(score, 960), undefined);
  assert.ok(at(score, 0) && at(score, 1920), "as vizinhas ficam");
  const beats = score.tracks[0].staves[0].bars[0].voices[0].beats;
  assert.ok(beats.some((b) => b.isRest && Math.abs(b.absolutePlaybackStart - 960) < 1));
});

test("várias notas: o trecho entre duas, articulação, meio tom e corda em todas", () => {
  let score = load();
  const staff = score.tracks[0].staves[0];
  const list = edit.notesOf(staff);
  const notes = edit.rangeOf(list[2], list[0]);
  assert.equal(notes.length, 3);
  assert.deepEqual(notes, list.slice(0, 3), "em ordem de tempo, de qualquer ponta");
  // A articulação liga em todas (a principal não tem) e desliga em todas.
  assert.equal(edit.toggleAll(alphaTab, notes, "palm-mute"), true);
  assert.ok(notes.every((n) => edit.techniquesOf(alphaTab, n).includes("palm-mute")));
  assert.equal(edit.toggleAll(alphaTab, notes, "palm-mute"), true);
  assert.ok(notes.every((n) => !edit.techniquesOf(alphaTab, n).includes("palm-mute")));
  // Meio tom em todas; se uma sairia do braço, nenhuma muda.
  const frets = notes.map((n) => n.fret);
  assert.equal(edit.transposeAll(notes, 1), true);
  assert.deepEqual(notes.map((n) => n.fret), frets.map((f) => f + 1));
  const low = Math.min(...notes.map((n) => n.fret));
  assert.equal(edit.transposeAll(notes, -(low + 1)), false);
  assert.deepEqual(notes.map((n) => n.fret), frets.map((f) => f + 1));
  // Outra corda, mesma altura, para todas (quando cabe em todas).
  const pitches = notes.map((n) => n.realValue);
  const tuning = staff.tuning;
  const delta = [1, -1].find((d) => notes.every((n) => {
    const target = n.string + d;
    if (target < 1 || target > tuning.length) return false;
    const fret = tuning[tuning.length - n.string] + n.fret - tuning[tuning.length - target];
    return fret >= 0 && fret <= edit.MAX_FRET;
  }));
  if (delta) {
    assert.equal(edit.moveAll(notes, delta), true);
    score = edit.refinish(alphaTab, score);
    const moved = edit.notesOf(score.tracks[0].staves[0]).slice(0, 3);
    assert.deepEqual(moved.map((n) => n.realValue), pitches, "a altura fica");
  }
});

test("nota nova: numa corda vazia da batida (acorde) e numa pausa, que vira nota", () => {
  let score = load();
  const note = at(score, 0);
  const beat = note.beat;
  const free = [1, 2, 3, 4, 5, 6].find((s) => s !== note.string);
  assert.equal(edit.insertNote(alphaTab, beat, note.string, 3), null, "a corda da nota está ocupada");
  assert.equal(edit.insertNote(alphaTab, beat, free, 30), null, "fora do braço");
  const added = edit.insertNote(alphaTab, beat, free, 7);
  assert.ok(added && beat.notes.length === 2);
  const caret = edit.caretOf(beat, free);
  score = reread(edit.refinish(alphaTab, score));
  barsAreWhole(score);
  const again = edit.resolveBeat(score, caret);
  assert.equal(again.notes.length, 2, "o acorde ficou no Guitar Pro");
  assert.ok(again.notes.some((n) => n.string === free && n.fret === 7));
  // Uma pausa vira nota.
  assert.equal(edit.toRest(alphaTab, at(score, 960)), true);
  score = edit.refinish(alphaTab, score);
  const rest = score.tracks[0].staves[0].bars[0].voices[0].beats.find((b) => b.isRest && Math.abs(b.absolutePlaybackStart - 960) < 1);
  assert.ok(rest);
  assert.ok(edit.insertNote(alphaTab, rest, 2, 5));
  score = reread(edit.refinish(alphaTab, score));
  barsAreWhole(score);
  assert.equal(at(score, 960).fret, 5);
});

test("copiar e colar: o trecho com as articulações, por cima do que estava, e noutra partitura", () => {
  let score = load();
  const staff = score.tracks[0].staves[0];
  const list = edit.notesOf(staff);
  // Duas notas do compasso 1, a primeira com palm mute e bend.
  edit.toggle(alphaTab, list[0], "palm-mute");
  edit.toggle(alphaTab, list[0], "bend-full");
  const clip = JSON.parse(JSON.stringify(edit.copy([list[0], list[1]])));
  assert.equal(clip.length, 1920);
  assert.equal(clip.events.length, 2);
  // Cola no compasso 2: as duas primeiras batidas de lá saem, o resto fica.
  const before = at(score, 5760);
  assert.equal(edit.paste(alphaTab, staff, 3840, clip), true);
  score = reread(edit.refinish(alphaTab, score));
  barsAreWhole(score);
  const pasted = at(score, 3840);
  assert.ok(edit.techniquesOf(alphaTab, pasted).includes("palm-mute"));
  assert.ok(edit.techniquesOf(alphaTab, pasted).includes("bend-full"));
  assert.ok(at(score, 4800), "a segunda colada");
  assert.equal(at(score, 5760).fret, before.fret, "o que vem depois do trecho fica");
  // Noutra partitura (outra música), no meio de uma nota: a de antes encurta até o trecho.
  let other = load();
  assert.equal(edit.paste(alphaTab, other.tracks[0].staves[0], 480, clip), true);
  other = reread(edit.refinish(alphaTab, other));
  barsAreWhole(other);
  assert.equal(at(other, 0).beat.playbackDuration, 480);
  assert.ok(at(other, 480) && at(other, 1440));
  // Passar do fim da música, não.
  const lastBar = other.tracks[0].staves[0].bars.at(-1).masterBar;
  assert.equal(edit.paste(alphaTab, other.tracks[0].staves[0], lastBar.start + 2880, clip), "end");
});

test("nota nova no meio de uma nota longa (que se divide, ligada) e no meio de uma pausa", () => {
  let score = load();
  const staff = score.tracks[0].staves[0];
  const long = at(score, 0);
  const free = [1, 2, 3, 4, 5, 6].find((s) => s !== long.string);
  // Na metade da primeira semínima, noutra corda: a semínima vira colcheia ligada a outra, e a nota nova entra junto.
  assert.equal(edit.insertAt(alphaTab, staff, 480, free, 5), true);
  score = reread(edit.refinish(alphaTab, score));
  barsAreWhole(score);
  const head = at(score, 0);
  assert.equal(head.beat.playbackDuration, 480);
  const at480 = edit.notesOf(score.tracks[0].staves[0]).filter((n) => Math.abs(n.beat.absolutePlaybackStart - 480) < 1);
  const held = at480.find((n) => n.string === long.string);
  assert.ok(held && held.isTieDestination && held.fret === long.fret, "o que soava continua, ligado");
  assert.equal(held.beat.playbackDuration, 480);
  const middle = at480.find((n) => n.string === free);
  assert.ok(middle && middle.fret === 5 && !middle.isTieDestination, "a nota nova ataca no meio");
  assert.ok(at(score, 960), "a seguinte fica");
  // Numa pausa: abre espaço com uma pausa e põe a nota no meio dela; a nota vai até a próxima.
  let other = load();
  assert.equal(edit.toRest(alphaTab, at(other, 960)), true);
  other = edit.refinish(alphaTab, other);
  assert.equal(edit.insertAt(alphaTab, other.tracks[0].staves[0], 1440, 2, 3), true);
  other = reread(edit.refinish(alphaTab, other));
  barsAreWhole(other);
  const filled = at(other, 1440);
  assert.ok(filled && filled.fret === 3);
  assert.deepEqual(edit.span(filled), { start: 1440, end: 1920 });
  // Perto demais do começo da nota: não.
  assert.equal(edit.insertAt(alphaTab, other.tracks[0].staves[0], 1930, 2, 3), "short");
});

test("voz 2: nota nova, figura e pausa na voz dela, sem mexer na voz 1", () => {
  let score = load();
  const staff = () => score.tracks[0].staves[0];
  const voiceOne = edit.timeline(staff(), 0).map((e) => [e.start, e.end]);
  // Uma nota na voz 2 no segundo tempo: vai até o fim do compasso, com pausa antes.
  assert.equal(edit.insertAt(alphaTab, staff(), 960, 1, 3, 1), true);
  score = reread(edit.refinish(alphaTab, score));
  const second = edit.notesOf(staff()).find((n) => n.beat.voice.index === 1);
  assert.ok(second && second.fret === 3 && Math.abs(second.beat.absolutePlaybackStart - 960) < 1);
  assert.deepEqual(edit.span(second), { start: 960, end: 3840 });
  assert.deepEqual(edit.timeline(staff(), 0).map((e) => [e.start, e.end]), voiceOne, "a voz 1 fica como estava");
  // A figura muda na voz 2 (sobra pausa nela).
  assert.equal(edit.setLength(alphaTab, second, 480), true);
  score = reread(edit.refinish(alphaTab, score));
  const shorter = edit.notesOf(staff()).find((n) => n.beat.voice.index === 1);
  assert.deepEqual(edit.span(shorter), { start: 960, end: 1440 });
  assert.deepEqual(edit.timeline(staff(), 0).map((e) => [e.start, e.end]), voiceOne);
  // Vira pausa: a voz 2 do compasso fica vazia de novo.
  assert.equal(edit.toRest(alphaTab, shorter), true);
  score = reread(edit.refinish(alphaTab, score));
  assert.ok(!edit.notesOf(staff()).some((n) => n.beat.voice.index === 1));
  assert.ok(staff().bars[0].voices[1].beats.every((b) => b.isEmpty || b.isRest));
});

test("compassos: pôr, apagar e mudar a fórmula em todas as pistas", () => {
  let score = load();
  const count = score.masterBars.length;
  const second = at(score, 3840).fret;
  // Um compasso antes do 2: o 2 de antes passa a começar um compasso depois.
  const put = edit.insertBar(alphaTab, score, 1);
  assert.equal(put.tick, 3840);
  assert.equal(put.newLength, 3840);
  score = reread(edit.refinish(alphaTab, put.score));
  barsAreWhole(score);
  assert.equal(score.masterBars.length, count + 1);
  assert.equal(at(score, 3840), undefined, "o compasso novo é pausa");
  assert.equal(at(score, 7680).fret, second);
  // Apagado de novo: tudo volta ao lugar.
  const gone = edit.deleteBar(alphaTab, score, 1);
  assert.deepEqual([gone.tick, gone.oldLength, gone.newLength], [3840, 3840, 0]);
  score = reread(edit.refinish(alphaTab, gone.score));
  barsAreWhole(score);
  assert.equal(score.masterBars.length, count);
  assert.equal(at(score, 3840).fret, second);
  // O compasso 1 em 2/4: as duas primeiras semínimas ficam, o resto sai, e o 2 começa em 1920.
  const two = edit.setTimeSignature(alphaTab, score, 0, 2, 4);
  assert.deepEqual([two.tick, two.oldLength, two.newLength], [0, 3840, 1920]);
  score = reread(edit.refinish(alphaTab, two.score));
  barsAreWhole(score);
  assert.equal(score.masterBars[0].timeSignatureNumerator, 2);
  assert.ok(at(score, 0) && at(score, 960));
  assert.equal(at(score, 1920).fret, second, "o compasso 2 vem logo depois");
  // E em 5/4: sobra uma semínima de pausa.
  const five = edit.setTimeSignature(alphaTab, score, 0, 5, 4);
  score = reread(edit.refinish(alphaTab, five.score));
  barsAreWhole(score);
  assert.equal(score.masterBars[1].start, 4800);
  assert.equal(edit.setTimeSignature(alphaTab, score, 0, 0, 4), "signature");
  assert.equal(edit.deleteBar(alphaTab, reread(edit.refinish(alphaTab, load())), 0).newLength, 0);
});

test("o que não dá: passar por cima da anterior, ficar curta demais", () => {
  const score = load();
  assert.equal(edit.retime(alphaTab, at(score, 960), -10, 900), "overlap");
  assert.equal(edit.retime(alphaTab, at(score, 960), 960, 970), "short");
});

test("dividir: duas ligadas com o mesmo som, o vibrato só na segunda, e a divisão sobrevive ao compasso refeito", () => {
  const core = require("../score-core.js");
  let score = load();
  for (const tick of [1920, 2880]) {
    assert.equal(edit.toRest(alphaTab, at(score, tick)), true);
    score = edit.refinish(alphaTab, score);
  }
  assert.equal(edit.setLength(alphaTab, at(score, 960), 1920), true);
  score = edit.refinish(alphaTab, score);
  edit.toggle(alphaTab, at(score, 960), "bend-full");
  score = edit.refinish(alphaTab, score);
  // Dividida no meio: a subida (no primeiro quarto da mínima) fica na primeira; a segunda fica sem bend e continua no
  // alto, como o Guitar Pro grava.
  assert.equal(edit.split(alphaTab, at(score, 960), 1920), true);
  score = edit.refinish(alphaTab, score);
  const tail = at(score, 1920);
  assert.ok(tail.isTieDestination && tail.tieOrigin === at(score, 960));
  const points = (n) => (n.bendPoints || []).map((p) => [p.offset, p.value]);
  assert.deepEqual(points(at(score, 960)), [[0, 0], [30, 4]]);
  assert.deepEqual(points(tail), []);
  assert.equal(edit.split(alphaTab, at(score, 960), 1920), "same");
  assert.equal(edit.split(alphaTab, at(score, 960), 965), "short");
  edit.toggle(alphaTab, tail, "vibrato");
  score = reread(edit.refinish(alphaTab, score));
  assert.equal(at(score, 960).vibrato, 0);
  assert.equal(at(score, 1920).vibrato, alphaTab.model.VibratoType.Slight);
  assert.deepEqual(points(at(score, 960)), [[0, 0], [30, 4]], "o Guitar Pro guarda a subida no lugar");
  // Na Lente, uma nota só: a mínima inteira, a subida no primeiro oitavo e o vibrato.
  const lens = core.trackNotes(score)[0].find((n) => n[0] === 960);
  assert.equal(lens[1], 1920);
  assert.equal(lens[5], 1);
  assert.deepEqual(lens.slice(7), [0, 0, 15, 4, 30, 4, 60, 4]);
  // A nota anda uma semínima: a divisão e o vibrato vão junto.
  assert.equal(edit.nudge(alphaTab, at(score, 960), 1, 960), true);
  score = edit.refinish(alphaTab, score);
  barsAreWhole(score);
  assert.ok(at(score, 2880).isTieDestination && at(score, 2880).vibrato);
  assert.ok(!at(score, 1920).isTieDestination && !at(score, 1920).vibrato);
  // O encaixe na nota inteira reparte o bend medido: sobe no primeiro sexto e fica; o vibrato continua na segunda.
  assert.ok(edit.fit(alphaTab, at(score, 1920), { pitch: at(score, 1920).realValue, bend: [[0, 0], [10, 2]], vibrato: true }));
  score = edit.refinish(alphaTab, score);
  assert.deepEqual(points(at(score, 1920)), [[0, 0], [20, 2]]);
  assert.deepEqual(points(at(score, 2880)), []);
  assert.ok(at(score, 2880).vibrato && !at(score, 1920).vibrato);
  // Dividida de novo, a ligada do meio entra na cadeia: cada uma vem da anterior (antes a de depois ficava presa à
  // primeira), e a nova continua o vibrato.
  assert.equal(edit.split(alphaTab, at(score, 2880), 3360), true);
  score = reread(edit.refinish(alphaTab, score));
  assert.equal(at(score, 1920).tieDestination, at(score, 2880));
  assert.equal(at(score, 2880).tieDestination, at(score, 3360));
  assert.ok(at(score, 3360).vibrato);
  assert.equal(core.trackNotes(score)[0].find((n) => n[0] === 1920)[1], 1920);
  // Como o Guitar Pro: o vibrato fica só na nota escolhida; o P.M. vai também para as ligadas seguintes e o let ring o
  // tira (os dois não convivem).
  edit.toggle(alphaTab, at(score, 2880), "vibrato");
  assert.ok(!at(score, 2880).vibrato && at(score, 3360).vibrato);
  edit.toggle(alphaTab, at(score, 1920), "palm-mute");
  assert.ok(at(score, 1920).isPalmMute && at(score, 2880).isPalmMute && at(score, 3360).isPalmMute);
  edit.toggle(alphaTab, at(score, 1920), "let-ring");
  assert.ok(at(score, 1920).isLetRing && !at(score, 1920).isPalmMute && !at(score, 3360).isPalmMute);
  assert.ok(!at(score, 2880).isLetRing, "o let ring fica só na nota");
  // O bend ligado na primeira parte: a ligada seguinte fica sem bend (continua no alto); um Hold que ela tivesse sai.
  at(score, 3360).addBendPoint(new alphaTab.model.BendPoint(0, 2));
  at(score, 3360).addBendPoint(new alphaTab.model.BendPoint(60, 2));
  edit.toggle(alphaTab, at(score, 2880), "bend-full");
  assert.deepEqual(points(at(score, 2880)), [[0, 0], [15, 4]]);
  assert.deepEqual(points(at(score, 3360)), []);
});

test("ligada (L), como no Guitar Pro: duas notas, o bend na primeira e o vibrato na segunda, ligada", () => {
  let score = load();
  const points = (n) => (n.bendPoints || []).map((p) => [p.offset, p.value]);
  assert.equal(edit.tie(alphaTab, at(score, 0)), "tie", "a primeira da música não tem de onde vir");
  edit.toggle(alphaTab, at(score, 0), "bend-full");
  edit.setFret(at(score, 960), 7);
  assert.equal(edit.tie(alphaTab, at(score, 960)), true);
  score = edit.refinish(alphaTab, score);
  const second = at(score, 960);
  assert.ok(second.isTieDestination && second.tieOrigin === at(score, 0));
  assert.equal(second.fret, 5, "a ligada fica na casa da de antes");
  assert.deepEqual(points(second), [], "e continua no alto do bend sem bend dela, como o Guitar Pro grava");
  assert.ok(edit.techniquesOf(alphaTab, second).includes("tie"));
  assert.ok(!edit.techniquesOf(alphaTab, second).includes("prebend"), "segurar não é pré-bend");
  edit.toggle(alphaTab, second, "wide-vibrato");
  score = reread(edit.refinish(alphaTab, score));
  assert.ok(at(score, 960).isTieDestination && at(score, 960).vibrato === alphaTab.model.VibratoType.Wide);
  assert.equal(at(score, 0).vibrato, 0);
  // O vibrato largo sai da ligada; e L de novo solta a nota, que ataca outra vez.
  edit.toggle(alphaTab, at(score, 960), "wide-vibrato");
  assert.equal(at(score, 960).vibrato, 0);
  assert.equal(edit.tie(alphaTab, at(score, 960)), true);
  score = reread(edit.refinish(alphaTab, score));
  assert.ok(!at(score, 960).isTieDestination && !at(score, 0).tieDestination);
});

test("vibrato numa ligada com Hold (como a importação do Songsterr grava): o Hold sai, com o mesmo som", () => {
  const core = require("../score-core.js");
  const { BendPoint, BendType } = alphaTab.model;
  const hold = (n, value) => {
    n.bendType = BendType.Hold;
    n.bendPoints = null;
    n.addBendPoint(new BendPoint(0, value));
    n.addBendPoint(new BendPoint(60, value));
  };
  // Compasso 1: bend inteiro, e duas ligadas que seguram o alto com Hold. Compasso 2: a ligada segura outra altura.
  let score = load();
  edit.toggle(alphaTab, at(score, 0), "bend-full");
  edit.toggle(alphaTab, at(score, 3840), "bend-full");
  for (const tick of [960, 1920, 4800]) {
    assert.equal(edit.tie(alphaTab, at(score, tick)), true);
    score = edit.refinish(alphaTab, score);
  }
  hold(at(score, 960), 4);
  hold(at(score, 1920), 4);
  hold(at(score, 4800), 2);
  score = reread(edit.refinish(alphaTab, score));
  assert.ok([960, 1920, 4800].every((tick) => at(score, tick).isTieDestination && at(score, tick).hasBend));
  const bends = (sc) => core.trackNotes(sc)[0].map((n) => [n[0], n.slice(7)]);
  const sound = bends(score);
  // O vibrato na primeira ligada: ela perde o Hold; a seguinte, sem vibrato, fica como estava.
  edit.toggle(alphaTab, at(score, 960), "vibrato");
  score = reread(edit.refinish(alphaTab, score));
  assert.ok(at(score, 960).vibrato && !at(score, 960).hasBend, "a ligada com vibrato fica sem o Hold");
  assert.ok(at(score, 1920).hasBend && !at(score, 1920).vibrato, "a sem vibrato fica com ele");
  assert.deepEqual(bends(score), sound, "o mesmo bend em toda a cadeia");
  edit.toggle(alphaTab, at(score, 1920), "wide-vibrato");
  score = reread(edit.refinish(alphaTab, score));
  assert.ok(!at(score, 1920).hasBend);
  assert.deepEqual(bends(score), sound);
  // Um Hold noutra altura que a de antes muda o som: fica.
  edit.toggle(alphaTab, at(score, 4800), "vibrato");
  score = reread(edit.refinish(alphaTab, score));
  assert.ok(at(score, 4800).vibrato && at(score, 4800).hasBend);
  assert.deepEqual(bends(score), sound);
});

test("apagar, colar e pôr nota numa ligada: a ligada não perde o que tem nem se prende a outra nota", () => {
  // Uma cadeia no compasso 1: bend inteiro em 0, ligada em 960, ligada com vibrato em 1920.
  const chain = () => {
    let score = load();
    edit.toggle(alphaTab, at(score, 0), "bend-full");
    for (const tick of [960, 1920]) {
      edit.tie(alphaTab, at(score, tick));
      score = edit.refinish(alphaTab, score);
    }
    edit.toggle(alphaTab, at(score, 1920), "vibrato");
    return edit.refinish(alphaTab, score);
  };
  const vibratoAt = (score, tick) => edit.notesOf(score.tracks[0].staves[0])
    .filter((n) => n.beat.absolutePlaybackStart <= tick && tick < n.beat.absolutePlaybackStart + n.beat.playbackDuration)
    .some((n) => n.vibrato);
  // Colar em 2400, no meio da ligada com vibrato: a parte de antes encurta e fica com o vibrato.
  let score = chain();
  const clip = edit.copy([at(score, 3840)]);
  assert.equal(edit.paste(alphaTab, score.tracks[0].staves[0], 2400, clip), true);
  score = edit.refinish(alphaTab, score);
  assert.ok(vibratoAt(score, 2000) && !vibratoAt(score, 1000), "o vibrato fica onde estava, até o colado");
  // Nota nova noutra corda em 2400: a ligada continua vibrando até o fim dela.
  score = chain();
  assert.equal(edit.insertAt(alphaTab, score.tracks[0].staves[0], 2400, 1, 3, 0), true);
  score = edit.refinish(alphaTab, score);
  assert.ok(vibratoAt(score, 2000) && vibratoAt(score, 2600), "o vibrato segue depois da nota nova");
  assert.ok(at(score, 2400) && edit.notesOf(score.tracks[0].staves[0]).some((n) =>
    Math.abs(n.beat.absolutePlaybackStart - 2400) < 1 && n.string === 1 && n.fret === 3 && !n.isTieDestination));
  // Apagar a cabeça de uma ligada: a seguinte ataca de novo, na casa dela (e não presa à nota de antes da pausa).
  score = load();
  edit.setFret(at(score, 1920), 7);
  edit.setFret(at(score, 2880), 7);
  edit.tie(alphaTab, at(score, 2880));
  score = edit.refinish(alphaTab, score);
  assert.ok(at(score, 2880).isTieDestination);
  assert.equal(edit.remove(at(score, 1920), alphaTab), true);
  score = edit.refinish(alphaTab, score);
  assert.ok(!at(score, 2880).isTieDestination && at(score, 2880).fret === 7);
});

test("o compasso refeito não muda o som: o bend de uma nota ligada continua no mesmo tempo", () => {
  // As 32 combinações (salvas pelo Guitar Pro 8): cada nota refeita na própria duração junta as ligadas sem articulação
  // numa figura maior; o bend medido no tempo (o que a Lente e o sintetizador tocam) tem de ser o mesmo.
  const core = require("../score-core.js");
  const bytes = new Uint8Array(fs.readFileSync(path.join(__dirname, "fixtures", "combinacoes.gp")));
  let score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes, new alphaTab.Settings());
  const sound = (sc) => new Map(core.trackNotes(sc)[0].map((n) => {
    const points = [];
    for (let i = 7; i + 1 < n.length; i += 2) points.push([n[i], n[i + 1]]);
    const at = (x) => {
      if (!points.length) return 0;
      if (x <= points[0][0]) return points[0][1];
      for (let i = 1; i < points.length; i++) {
        const [x0, y0] = points[i - 1];
        const [x1, y1] = points[i];
        if (x <= x1) return x1 > x0 ? y0 + ((y1 - y0) * (x - x0)) / (x1 - x0) : y1;
      }
      return points[points.length - 1][1];
    };
    return [`${n[0]}/${n[3]}`, [n[1], n[5], ...Array.from({ length: 13 }, (_, k) => Math.round(at(k * 5) * 2) / 2)].join()];
  }));
  const before = sound(score);
  // Pelo tique e pela corda (o endereço muda quando as ligadas se juntam).
  for (const v of [0, 1]) {
    const heads = edit.timeline(score.tracks[0].staves[0], v).map((e) => [e.start, edit.tabString(e.beat.notes[0])]);
    for (const [tick, string] of heads) {
      const note = edit.findNote(score, 0, tick, string);
      const span = edit.span(note);
      assert.equal(edit.setLength(alphaTab, note, span.end - span.start), true, `${tick}`);
      score = edit.refinish(alphaTab, score);
    }
  }
  assert.deepEqual(sound(score), before);
});

test("acorde em que só uma nota segue ligada: refazer o compasso não estica a outra", () => {
  // Como no solo da Sunshine (c. 72): colcheia pontuada com duas notas e a semicolcheia seguinte só com uma, ligada.
  const m = alphaTab.model;
  let score = load();
  const voice = score.tracks[0].staves[0].bars[0].voices[0];
  voice.beats = [];
  const beat = (duration, dots, notes) => {
    const b = new m.Beat();
    b.duration = duration;
    b.dots = dots;
    for (const [string, fret, tie] of notes) {
      const n = new m.Note();
      n.string = string;
      n.fret = fret;
      n.isTieDestination = tie;
      b.addNote(n);
    }
    voice.addBeat(b);
  };
  beat(m.Duration.Eighth, 1, [[4, 12, false], [5, 10, false]]);
  beat(m.Duration.Sixteenth, 0, [[5, 10, true]]);
  beat(m.Duration.Half, 1, [[4, 12, false]]);
  score = edit.refinish(alphaTab, score);
  assert.equal(edit.setLength(alphaTab, at(score, 0), 720), true);
  score = edit.refinish(alphaTab, score);
  const first = score.tracks[0].staves[0].bars[0].voices[0].beats[0];
  assert.equal(first.playbackDuration, 720, "a colcheia pontuada continua");
  assert.ok(at(score, 720) && at(score, 720).isTieDestination && at(score, 720).string === 5);
});

test("copiar e colar uma nota ligada leva as partes como estão: o bend no mesmo tempo e o vibrato da ligada", () => {
  const bytes = new Uint8Array(fs.readFileSync(path.join(__dirname, "fixtures", "combinacoes.gp")));
  let score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes, new alphaTab.Settings());
  const staff = () => score.tracks[0].staves[0];
  const parts = (bar) => staff().bars[bar - 1].voices[0].beats.filter((b) => b.notes.length).map((b) => [b.playbackStart,
    b.playbackDuration, b.notes[0].isTieDestination, b.notes[0].vibrato, (b.notes[0].bendPoints || []).map((p) => [p.offset, p.value])]);
  // O c. 31 (dividido: bend, e a ligada com vibrato) colado no c. 29, pelo recorte em JSON (como vai para o app).
  const original = parts(31);
  const clip = JSON.parse(JSON.stringify(edit.copy([staff().bars[30].voices[0].beats[0].notes[0]])));
  assert.equal(edit.paste(alphaTab, staff(), score.masterBars[28].start, clip, 0), true);
  score = edit.refinish(alphaTab, score);
  assert.deepEqual(parts(29), original);
  // No quarto tempo de um compasso: a primeira parte se divide na barra e o bend sobe no mesmo tempo (uma semínima).
  assert.equal(edit.paste(alphaTab, staff(), score.masterBars[22].start + 2880, clip, 0), true);
  score = edit.refinish(alphaTab, score);
  const head = staff().bars[22].voices[0].beats.find((b) => b.playbackStart === 2880).notes[0];
  assert.deepEqual(head.bendPoints.map((p) => [p.offset, p.value]), [[0, 0], [60, 4]]);
  const tail = staff().bars[23].voices[0].beats.find((b) => b.playbackStart === 960).notes[0];
  assert.ok(tail.isTieDestination && tail.vibrato);
});

test("a última nota não passa do fim da música: mover, alongar e o passo da grade recusam sem mudar nada", () => {
  let score = load();
  const staff = () => score.tracks[0].staves[0];
  const shape = () => edit.timeline(staff(), 0).map((e) => [e.start, e.end, e.beat.notes.map((n) => [n.string, n.fret])]);
  const before = shape();
  const last = () => edit.notesOf(staff()).at(-1);
  const bar = staff().bars.at(-1).masterBar;
  const end = bar.start + bar.calculateDuration();
  const span = edit.span(last());
  assert.equal(span.end, end, "a fixture acaba na última nota");
  // Antes, o retime dizia true e a nota sumia no compasso refeito (16 notas viravam 15).
  assert.equal(edit.retime(alphaTab, last(), span.start + 120, span.end + 120), "end");
  assert.equal(edit.nudge(alphaTab, last(), 1, 240), "end");
  assert.equal(edit.setLength(alphaTab, last(), end - span.start + 480), "end");
  score = edit.refinish(alphaTab, score);
  assert.deepEqual(shape(), before);
  assert.equal(edit.notesOf(staff()).length, 16);
  // Para trás, e encurtando, dá.
  assert.equal(edit.nudge(alphaTab, last(), -1, 240), true);
  score = edit.refinish(alphaTab, score);
  assert.deepEqual(edit.span(last()), { start: span.start - 240, end: span.end - 240 });
});

test("duas vozes: copiar leva as duas, colar põe cada uma na sua, e um recorte de uma voz cola na voz pedida", () => {
  let score = load();
  const staff = () => score.tracks[0].staves[0];
  assert.equal(edit.insertAt(alphaTab, staff(), 1440, 1, 3, 1), true);
  score = edit.refinish(alphaTab, score);
  const notes = edit.notesOf(staff());
  const a = notes.find((n) => n.beat.voice.index === 0 && Math.abs(n.beat.absolutePlaybackStart - 960) < 1);
  const b = notes.find((n) => n.beat.voice.index === 1);
  assert.deepEqual(edit.span(b), { start: 1440, end: 3840 });
  // Antes, o recorte levava só a voz da primeira nota (a da voz 2 ficava de fora, e o Recortar a apagava).
  const clip = JSON.parse(JSON.stringify(edit.copy([a, b])));
  assert.deepEqual(clip.voices, [0, 1]);
  assert.equal(clip.length, 2880);
  assert.deepEqual(clip.events.filter((e) => e.voice === 1).map((e) => [e.offset, e.length]), [[480, 2400]]);
  assert.equal(clip.events.filter((e) => e.voice === 0).length, 3);
  // Colado no compasso 2: a voz 1 e a voz 2 cada uma na sua, no mesmo lugar uma da outra.
  assert.equal(edit.paste(alphaTab, staff(), 3840 + 960, clip), true);
  score = reread(edit.refinish(alphaTab, score));
  barsAreWhole(score);
  const second = edit.notesOf(staff()).filter((n) => n.beat.voice.index === 1 && !n.isTieDestination);
  assert.deepEqual(second.map((n) => [n.beat.absolutePlaybackStart, n.fret]), [[1440, 3], [5280, 3]]);
  assert.equal(at(score, 4800).fret, a.fret);
  // Um recorte só da voz 1, colado na voz 2 (a nota escolhida é da voz 2): a voz 1 fica como estava.
  const one = JSON.parse(JSON.stringify(edit.copy([edit.notesOf(staff()).find((n) => n.beat.voice.index === 0)])));
  assert.equal(one.voices, undefined);
  const voiceOne = edit.timeline(staff(), 0).map((e) => [e.start, e.end]);
  assert.equal(edit.paste(alphaTab, staff(), 1440, one, 1), true);
  score = reread(edit.refinish(alphaTab, score));
  assert.deepEqual(edit.timeline(staff(), 0).map((e) => [e.start, e.end]), voiceOne);
  assert.deepEqual(edit.timeline(staff(), 1).map((e) => [e.start, e.end])[0], [1440, 2400]);
  // A nota de cada voz achada pela voz: no mesmo tique e na mesma corda, a da voz pedida.
  const v2 = edit.notesOf(staff()).find((n) => n.beat.voice.index === 1);
  const found = edit.findNote(score, 0, v2.beat.absolutePlaybackStart, edit.tabString(v2), 1);
  assert.equal(found, v2);
});

console.log(`${passed} verificações passaram`);
