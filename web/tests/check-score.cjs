// node web/tests/check-score.cjs [arquivo.gp …]: as contas da página (score-core.js) e o desenho do alphaTab do
// projeto no node com as larguras da página (barras e notas no tempo), nos Guitar Pro de tests/fixtures (feitos pelo
// conversor do motor) ou nos arquivos dados.
"use strict";
const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const core = require("../score-core.js");

let passed = 0;
function test(name, body) {
  body();
  passed += 1;
  console.log("ok", name);
}

// Compassos 4/4 de 2 s a partir de 1 s, como o mapa que o motor faz dos pontos do Songsterr.
const points = core.cleanPoints([
  { tick: 0, seconds: 1, kind: "detected" },
  { tick: 1920, seconds: 2, kind: "interpolated" },
  { tick: 3840, seconds: 3, kind: "detected" },
  { tick: 7680, seconds: 5.5, kind: "detected" },
]);

test("segundos e tiques pelo mapa", () => {
  assert.equal(core.secondsToTick(points, 1), 0);
  assert.equal(core.secondsToTick(points, 2.5), 2880);
  assert.equal(core.secondsToTick(points, 4.25), 5760);
  assert.equal(core.tickToSeconds(points, 5760), 4.25);
  // Antes do primeiro ponto, a reta do primeiro trecho.
  assert.equal(core.secondsToTick(points, 0), -1920);
  assert.ok(Math.abs(core.tickToSeconds(points, core.secondsToTick(points, 3.7)) - 3.7) < 1e-9);
});

test("o mapa acompanha um compasso posto, apagado ou com outra fórmula", () => {
  // Compassos 4/4 de 2 s (pontos em 0, 3840, 7680, 11520).
  const map = core.cleanPoints([
    { tick: 0, seconds: 0, kind: "detected" }, { tick: 1920, seconds: 1, kind: "interpolated" },
    { tick: 3840, seconds: 2, kind: "detected" }, { tick: 7680, seconds: 4, kind: "detected" },
    { tick: 11520, seconds: 6, kind: "detected" },
  ]);
  // Um compasso posto antes do 2 (tique 3840): o 2 de antes continua em 2 s, agora no tique 7680; o 1 e o novo
  // repartem os 2 s do 1 pelos tiques (metade cada), o meio do 1 junto.
  const put = core.reshapePoints(map, 3840, 0, 3840);
  assert.deepEqual(put.map((p) => [p.tick, p.seconds]), [[0, 0], [1920, 0.5], [3840, 1], [7680, 2], [11520, 4], [15360, 6]]);
  // Apagado o compasso 2 (3840–7680): o 3 continua em 4 s, agora no tique 3840; o 1 estica por igual até lá.
  const gone = core.reshapePoints(map, 3840, 3840, 0);
  assert.deepEqual(gone.map((p) => [p.tick, p.seconds]), [[0, 0], [1920, 2], [3840, 4], [7680, 6]]);
  // O compasso 1 em 2/4: o de dentro estica no tempo dele, o 2 continua em 2 s, agora no tique 1920.
  const two = core.reshapePoints(map, 0, 3840, 1920);
  assert.deepEqual(two.map((p) => [p.tick, p.seconds]), [[0, 0], [960, 1], [1920, 2], [5760, 4], [9600, 6]]);
  // O último compasso apagado: a música termina onde ele começava.
  const last = core.reshapePoints(map, 7680, 3840, 0);
  assert.deepEqual(last.map((p) => [p.tick, p.seconds]).at(-1), [7680, 6]);
});

test("pontos fora de ordem ou repetidos saem", () => {
  const clean = core.cleanPoints([{ tick: 960, seconds: 2 }, { tick: 0, seconds: 1 }, { tick: 960, seconds: 2.1 }, { tick: 1920, seconds: 1.5 }, { tick: "x" }]);
  assert.deepEqual(clean.map((p) => p.tick), [0, 960]);
});

test("âncoras: no mesmo tique fica o maior x, e x nunca volta", () => {
  const anchors = core.cleanAnchors([[3840, 300], [3840, 360], [0, 136], [960, 173], [1920, 150], [7680, 480]]);
  assert.deepEqual(anchors, [[0, 136], [960, 173], [3840, 360], [7680, 480]]);
  assert.equal(core.tickAtX(anchors, 154.5), 480);
  assert.equal(core.tickAtX(anchors, 0), 0);
});

test("a rolagem segue a reta antes da primeira âncora e depois da última", () => {
  const follow = [[0, 500], [3840, 700]];
  assert.equal(core.followX(follow, 1920), 600);
  assert.equal(core.followX(follow, -1920), 400);
  assert.equal(core.followX(follow, 5760), 800);
});

test("antes do primeiro ponto do mapa e depois do último, a pauta anda na escala da Fita", () => {
  // A primeira batida longa (um toque do Bater junto): 1 s para 960 tiques, depois 0,5 s.
  const map = core.cleanPoints([{ tick: 0, seconds: 2 }, { tick: 960, seconds: 3 }, { tick: 1920, seconds: 3.5 }]);
  const anchors = [[0, 500], [1920, 700]];
  assert.equal(core.xAtSeconds(map, anchors, 2, 100), 500);
  assert.equal(core.xAtSeconds(map, anchors, 1.5, 100), 450);
  assert.equal(core.xAtSeconds(map, anchors, 4, 100), 750);
  assert.equal(core.xAtSeconds(map, anchors, 3, 100), 600);
});

test("largura dos compassos: de um início de compasso ao seguinte, a duração na escala", () => {
  const widths = core.barWidths([{ seconds: 2, pre: 60 }, { seconds: 2, pre: 15 }, { seconds: 1, pre: 15 }], 100, 24);
  assert.deepEqual(widths, [245, 200, 115]);
  // Do início de um compasso ao do seguinte: largura - pre + pre do seguinte.
  assert.equal(widths[0] - 60 + 15, 200);
  assert.deepEqual(core.barWidths([{ seconds: 0.05, pre: 15 }], 100, 24), [24]);
});

test("o som do play só sai depois da latência", () => {
  const clock = core.nextClock(null, { seconds: 10, playing: true, rate: 1, delay: 0.2 }, 1000, 0.04);
  assert.equal(core.estimate(clock, 1100), 10);
  assert.ok(Math.abs(core.estimate(clock, 2200) - 11) < 1e-9);
});

test("relógio extrapolado e avisos pequenos ignorados", () => {
  let clock = core.nextClock(null, { seconds: 10, playing: true, rate: 1 }, 1000, 0.04);
  assert.equal(core.estimate(clock, 2000), 11);
  assert.equal(core.nextClock(clock, { seconds: 11.02, playing: true, rate: 1 }, 2000, 0.04), clock);
  const moved = core.nextClock(clock, { seconds: 20, playing: true, rate: 1 }, 2000, 0.04);
  assert.equal(core.estimate(moved, 2000), 20);
  const slow = core.nextClock(moved, { seconds: 20, playing: true, rate: 0.5 }, 2000, 0.04);
  assert.equal(core.estimate(slow, 4000), 21);
  const paused = core.nextClock(slow, { seconds: 21, playing: false, rate: 0.5 }, 4000, 0.04);
  assert.equal(core.estimate(paused, 9000), 21);
});

test("o cursor fica a 40 % da largura", () => {
  assert.equal(core.scrollFor(1000, 500), 800);
  assert.equal(core.scrollFor(100, 500), -100);
  assert.equal(core.scrollFor(1000, 500, 0.7), 650);
});

const fixtures = path.join(__dirname, "fixtures");
const given = process.argv.slice(2);
test("o relógio dá a volta no fim do loop, como o motor de áudio", () => {
  const loop = [10, 14];
  const clock = core.nextClock(null, { seconds: 12, playing: true, rate: 1, delay: 0 }, 0, 0.04, loop);
  assert.equal(core.estimate(clock, 1000, loop), 13);
  assert.equal(core.estimate(clock, 3000, loop), 11);
  assert.equal(core.estimate(clock, 7000, loop), 11);
  // Tocando de depois do fim do loop, segue solto (o motor não entra no loop).
  const after = core.nextClock(null, { seconds: 15, playing: true, rate: 1, delay: 0 }, 0, 0.04, loop);
  assert.equal(core.estimate(after, 2000, loop), 17);
  // Um aviso já com a volta dada não é diferente da extrapolação: não é aceito à toa.
  assert.equal(core.nextClock(clock, { seconds: 11.01, playing: true, rate: 1 }, 3000, 0.04, loop), clock);
});

test("com a música no loop, a pauta para no pino que o app escolheu", () => {
  assert.equal(core.windowStart(11, [10, 14], 6), 6);
  assert.equal(core.windowStart(14, [10, 14], 7.5), 7.5);
  // Sem pino, sem loop, ou com o cursor fora dele: a janela segue o cursor.
  assert.equal(core.windowStart(12, [10, 14], null), null);
  assert.equal(core.windowStart(12, null, 6), null);
  assert.equal(core.windowStart(9, [10, 14], 6), null);
});

const files = given.length ? given : fs.readdirSync(fixtures).filter((f) => f.endsWith(".gp")).map((f) => path.join(fixtures, f));
if (files.length) {
  const alphaTab = require("../vendor/alphatab/alphaTab.js");
  for (const file of files) {
    test(`compassos e notas no tempo, no alphaTab, em ${path.basename(file)}`, () => {
      const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(file)), new alphaTab.Settings());
      const settings = new alphaTab.Settings();
      settings.core.engine = "svg";
      settings.display.layoutMode = alphaTab.LayoutMode.Horizontal;
      settings.display.staveProfile = alphaTab.StaveProfile.Tab;
      const renderer = new alphaTab.rendering.ScoreRenderer(settings);
      renderer.width = 1200;
      renderer.renderScore(score, [0]);
      // As notas para o espectro: em ordem de tique, com altura e casa de verdade (a pista 0 é de cordas).
      const notes = core.trackNotes(score)[0];
      assert.ok(notes.length > 0 && notes.every((n) => Number.isFinite(n[0]) && n[1] > 0 && n[2] >= 28 && n[2] <= 100));
      assert.ok(notes.every((n, i) => i === 0 || n[0] >= notes[i - 1][0]));
      let tick = 0;
      for (const masterBounds of renderer.boundsLookup.staffSystems[0].bars) {
        const master = score.masterBars[masterBounds.index];
        // A régua do motor soma as fórmulas de compasso desde zero: o alphaTab tem de concordar.
        assert.equal(master.start, tick);
        tick += master.calculateDuration();
      }
      // Com as larguras da página (120 bpm, 100 px por segundo): de uma barra à seguinte, a duração na escala; dentro
      // do compasso, as notas no seu tempo (o alphaTab do projeto espaça pela duração).
      const lookup = renderer.boundsLookup.staffSystems[0].bars;
      const sizes = score.masterBars.map((m, i) => ({
        seconds: m.calculateDuration() / 1920,
        pre: Math.max(0, lookup[i].bars[0].beats[0].visualBounds.x - lookup[i].realBounds.x),
      }));
      assert.ok(sizes[0].pre > 20, "o primeiro compasso tem clave e fórmula");
      assert.ok(sizes.slice(1).every((b) => b.pre < 1), "a barra e o número não ocupam largura");
      const widths = core.barWidths(sizes, 100, 24);
      score.tracks[0].staves.forEach((staff) => staff.bars.forEach((bar, i) => (bar.displayWidth = widths[i])));
      const sized = new alphaTab.rendering.ScoreRenderer(settings);
      sized.width = 1200;
      sized.renderScore(score, [0]);
      const bars = sized.boundsLookup.staffSystems[0].bars;
      const starts = bars.map((b, i) => b.realBounds.x + sizes[i].pre);
      for (let i = 0; i + 1 < starts.length; i++) {
        assert.ok(Math.abs(starts[i + 1] - starts[i] - sizes[i].seconds * 100) < 1, `compasso ${i + 1}: ${starts[i + 1] - starts[i]}`);
        // As notas do compasso numa reta do tempo, na escala de 100 px por segundo menos a folga das pontas.
        const beats = bars[i].bars[0].beats;
        const first = beats[0];
        const last = beats[beats.length - 1];
        const tickOf = (b) => b.beat.absolutePlaybackStart;
        if (beats.length < 2) {
          continue;
        }
        const slope = (last.onNotesX - first.onNotesX) / (tickOf(last) - tickOf(first));
        assert.ok(slope * 1920 > 85 && slope * 1920 <= 100.5, `compasso ${i + 1}: ${slope * 1920} px por segundo`);
        for (const beat of beats) {
          const expected = first.onNotesX + (tickOf(beat) - tickOf(first)) * slope;
          assert.ok(Math.abs(beat.onNotesX - expected) < 1, `compasso ${i + 1}: ${beat.onNotesX} em vez de ${expected}`);
        }
      }
    });
  }
}
test("modo página: a batida que toca pelo tique", () => {
  const ticks = [0, 480, 960, 1920];
  assert.equal(core.beatIndexAt(ticks, -1), -1);
  assert.equal(core.beatIndexAt(ticks, 0), 0);
  assert.equal(core.beatIndexAt(ticks, 959), 1);
  assert.equal(core.beatIndexAt(ticks, 960), 2);
  assert.equal(core.beatIndexAt(ticks, 5000), 3);
});

console.log(`${passed} verificações passaram`);
