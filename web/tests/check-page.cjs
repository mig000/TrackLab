// node web/tests/check-page.cjs: a ponte da página (score.js) com o app, no alphaTab do node e sem desenhar: o que o
// app pede pela `window.tracklab` (colar, recortar, pôr pausa, a gravação já) muda a partitura certa e manda ao app o
// que deve. A página roda numa caixa (vm) com um DOM mínimo; as funções de desenho saem e o fim expõe o estado.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const alphaTab = require("../vendor/alphatab/alphaTab.js");
const edit = require("../score-edit.js");
const core = require("../score-core.js");

let passed = 0;
function test(name, body) {
  body();
  passed += 1;
  console.log("ok", name);
}

const bytes = new Uint8Array(fs.readFileSync(path.join(__dirname, "fixtures", "quatro-por-quatro.gp")));
const load = () => alphaTab.importer.ScoreLoader.loadScoreFromBytes(bytes, new alphaTab.Settings());

// A página com a partitura `score`: devolve a `tracklab` dela, o estado, as mensagens ao app e os temporizadores.
function page(score) {
  const posted = [];
  const timers = new Map();
  let next = 0;
  const element = () => ({
    children: [], style: {}, dataset: {}, hidden: false,
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener() {}, appendChild() {}, removeChild() {}, setAttribute() {},
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 1000, height: 100, right: 1000, bottom: 100 }),
    clientWidth: 1000, clientHeight: 100,
  });
  const document = { getElementById: element, createElement: element, body: element(), documentElement: element() };
  const window = {
    trackCore: core, trackEdit: edit, addEventListener() {}, requestAnimationFrame() {},
    setTimeout(fn) { timers.set(++next, fn); return next; },
    clearTimeout(id) { timers.delete(id); },
    webkit: { messageHandlers: { tracklab: { postMessage(message) { posted.push(message); } } } },
  };
  let source = fs.readFileSync(path.join(__dirname, "..", "score.js"), "utf8");
  for (const name of ["render", "drawSelection", "drawDurations"]) {
    const before = source;
    source = source.replace(new RegExp(`function ${name}\\(([^)]*)\\) \\{`), `function ${name}($1) { return;`);
    assert.notEqual(source, before, `a página tem a função ${name}`);
  }
  const ready = '  post({ type: "ready" });\n})();';
  assert.ok(source.includes(ready), "a página termina mandando ready");
  source = source.replace(ready, '  window.inside = { state, choose };\n' + ready);
  vm.runInNewContext(source, {
    window, document, alphaTab, performance: { now: () => 0 },
    btoa: (text) => Buffer.from(text, "binary").toString("base64"),
    atob: (text) => Buffer.from(text, "base64").toString("binary"),
  });
  window.inside.state.score = score;
  const fire = () => { for (const [id, fn] of [...timers]) { timers.delete(id); fn(); } };
  return { tracklab: window.tracklab, state: window.inside.state, choose: window.inside.choose, posted, timers, fire };
}

const staffOf = (p) => p.state.score.tracks[0].staves[0];
const voiceShape = (staff, v) => edit.timeline(staff, v).map((e) => [e.start, e.end, e.beat.notes.map((n) => [n.string, n.fret])]);
// A partitura com uma nota na voz 2 no tique `tick` (corda 1, casa 3).
function withSecondVoice(tick) {
  let score = load();
  assert.equal(edit.insertAt(alphaTab, score.tracks[0].staves[0], tick, 1, 3, 1), true);
  return edit.refinish(alphaTab, score);
}

test("colar com uma nota da voz 2 escolhida cola na voz 2, e a escolha fica nela", () => {
  const p = page(withSecondVoice(960));
  const staff = staffOf(p);
  const source = edit.notesOf(staff).find((n) => n.beat.voice.index === 0 && n.beat.absolutePlaybackStart === 0);
  const clip = JSON.parse(JSON.stringify(edit.copy([source])));
  clip.events[0].notes[0].fret = 9;
  const target = edit.notesOf(staff).find((n) => n.beat.voice.index === 1);
  const voiceOne = voiceShape(staff, 0);
  p.choose(edit.pathOf(target));
  p.tracklab.edit("paste", clip);
  const after = staffOf(p);
  // Antes, a página colava na voz 1 (a casa 9 por cima da nota de lá) e a voz 2 ficava igual.
  assert.deepEqual(voiceShape(after, 0), voiceOne);
  const pasted = edit.notesOf(after).find((n) => n.beat.voice.index === 1 && !n.isTieDestination);
  assert.equal(pasted.fret, 9);
  assert.equal(edit.resolve(p.state.score, p.state.selected).beat.voice.index, 1);
});

test("colar no cursor de inserção no meio de uma nota entra no tique do cursor, não no começo da nota", () => {
  const p = page(load());
  const staff = staffOf(p);
  const note = edit.notesOf(staff)[0];
  const clip = JSON.parse(JSON.stringify(edit.copy([edit.notesOf(staff)[1]])));
  // O cursor numa corda vazia, no meio da primeira semínima (tique 480).
  p.state.caret = [...edit.caretOf(note.beat, 1), 480];
  p.tracklab.edit("paste", clip);
  const picked = edit.resolve(p.state.score, p.state.selected);
  assert.equal(picked.beat.absolutePlaybackStart, 480);
  // A nota de antes encurta até o cursor (antes, a colada tomava o lugar dela desde o tique 0).
  const head = edit.notesOf(staffOf(p)).find((n) => n.beat.absolutePlaybackStart === 0);
  assert.ok(head && edit.span(head).end === 480);
});

test("recortar notas das duas vozes leva as duas ao recorte e deixa pausa só nelas", () => {
  const p = page(withSecondVoice(1440));
  const staff = staffOf(p);
  const a = edit.notesOf(staff).find((n) => n.beat.voice.index === 0 && n.beat.absolutePlaybackStart === 960);
  const b = edit.notesOf(staff).find((n) => n.beat.voice.index === 1);
  const count = edit.notesOf(staff).filter((n) => n.beat.voice.index === 0).length;
  p.choose(edit.pathOf(a));
  p.state.group = [edit.pathOf(a), edit.pathOf(b)];
  p.tracklab.edit("cut");
  const clip = p.posted.find((m) => m.type === "clip").clip;
  // Antes, o recorte levava 1 nota e as duas viravam pausa (a da voz 2 se perdia).
  assert.deepEqual(clip.voices, [0, 1]);
  assert.deepEqual(clip.events.filter((e) => e.voice === 1).map((e) => e.notes.length), [1]);
  const left = edit.notesOf(staffOf(p));
  assert.ok(!left.some((n) => n.beat.voice.index === 1 && !n.isTieDestination));
  assert.ok(!left.some((n) => n.beat.voice.index === 0 && n.beat.absolutePlaybackStart === 960));
  assert.equal(left.filter((n) => n.beat.voice.index === 0).length, count - 1, "na voz 1, só a recortada sai");
});

test("pausa em duas notas no mesmo tique, uma em cada voz: as duas viram pausa", () => {
  const p = page(withSecondVoice(960));
  const staff = staffOf(p);
  const a = edit.notesOf(staff).find((n) => n.beat.voice.index === 0 && n.beat.absolutePlaybackStart === 960);
  const b = edit.notesOf(staff).find((n) => n.beat.voice.index === 1);
  p.choose(edit.pathOf(a));
  p.state.group = [edit.pathOf(a), edit.pathOf(b)];
  p.tracklab.edit("rest");
  const left = edit.notesOf(staffOf(p));
  // Antes, as duas eram "a mesma batida" (o mesmo tique) e só a primeira virava pausa.
  assert.ok(!left.some((n) => n.beat.absolutePlaybackStart === 960));
  assert.ok(!left.some((n) => n.beat.voice.index === 1));
});

test("a gravação pendente sai já quando o app pede (fechar a música, sair da edição ou do app)", () => {
  const p = page(load());
  assert.equal(p.tracklab.flush(), null, "sem mudança, nada a gravar");
  const note = edit.notesOf(staffOf(p))[0];
  const fret = note.fret;
  p.choose(edit.pathOf(note));
  p.tracklab.edit("fret", fret + 1);
  assert.equal(p.posted.filter((m) => m.type === "save").length, 0, "a gravação espera 1,5 s");
  const gp = p.tracklab.flush();
  assert.ok(typeof gp === "string" && gp.length > 100);
  const saved = alphaTab.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(Buffer.from(gp, "base64")),
    new alphaTab.Settings());
  assert.equal(edit.notesOf(saved.tracks[0].staves[0])[0].fret, fret + 1);
  // A espera de 1,5 s foi cancelada: não grava de novo, e um segundo pedido não tem nada.
  p.fire();
  assert.equal(p.posted.filter((m) => m.type === "save").length, 0);
  assert.equal(p.tracklab.flush(), null);
});

test("o bend do editor da coluna vale para todas as notas escolhidas; fora do formato, aviso e nada muda", () => {
  const p = page(load());
  const list = edit.notesOf(staffOf(p));
  p.choose(edit.pathOf(list[0]));
  p.state.group = [edit.pathOf(list[0]), edit.pathOf(list[1])];
  p.tracklab.edit("bend", { points: [[0, 2], [15, 4]] });
  const after = edit.notesOf(staffOf(p));
  for (const n of after.slice(0, 2)) assert.deepEqual(n.bendPoints.map((b) => [b.offset, b.value]), [[0, 2], [15, 4]]);
  assert.ok(!after[2].hasBend);
  const notices = p.posted.filter((m) => m.type === "notice").length;
  p.tracklab.edit("bend", { points: [[0, 0], [15, 4], [30, 0], [45, 4], [60, 4]] });
  assert.equal(p.posted.filter((m) => m.type === "notice").length, notices + 1);
  assert.deepEqual(edit.notesOf(staffOf(p))[0].bendPoints.map((b) => [b.offset, b.value]), [[0, 2], [15, 4]]);
  // A coluna recebe o bend da nota escolhida.
  const selection = p.posted.filter((m) => m.type === "selection").pop();
  assert.deepEqual(selection.note.bend, [[0, 2], [15, 4]]);
  assert.equal(selection.note.carried, 0);
});

test("o corretor manda várias notas de uma vez: um passo só do Desfazer, e as que não acha ficam de fora", () => {
  const p = page(load());
  const list = edit.notesOf(staffOf(p));
  const strings = staffOf(p).tuning.length;
  const at = (n) => ({ track: 0, tick: n.beat.absolutePlaybackStart, string: strings - n.string + 1 });
  const undo = p.state.undo.length;
  const second = list[1].realValue;
  p.tracklab.edit("fitMany", [
    { ...at(list[0]), pitch: list[0].realValue, bend: [[0, 0], [15, 4]], vibrato: true, trill: null },
    { ...at(list[1]), pitch: second + 1, bend: null, vibrato: false, trill: null },
    { track: 0, tick: 999999, string: 1, pitch: 60, bend: null, vibrato: false, trill: null },
  ]);
  const after = edit.notesOf(staffOf(p));
  assert.deepEqual(after[0].bendPoints.map((b) => [b.offset, b.value]), [[0, 0], [15, 4]]);
  assert.ok(after[0].vibrato);
  assert.equal(after[1].realValue, second + 1);
  assert.equal(p.state.undo.length, undo + 1, "um passo só");
  const reply = p.posted.filter((m) => m.type === "fitted").pop();
  assert.deepEqual([reply.count, reply.asked], [2, 3]);
  p.tracklab.edit("undo");
  assert.ok(!edit.notesOf(staffOf(p))[0].hasBend);
});

console.log(`${passed} verificações passaram`);
