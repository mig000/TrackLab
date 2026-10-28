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
  assert.equal(core.scrollFor(100, 500), 0);
});

const fixtures = path.join(__dirname, "fixtures");
const given = process.argv.slice(2);
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
console.log(`${passed} verificações passaram`);
