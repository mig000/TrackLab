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
  assert.equal(edit.describe(alphaTab, found).string, edit.tabString(b));
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
});

console.log(`${passed} verificações passaram`);
