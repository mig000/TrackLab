// node web/tests/check-score.cjs [arquivo.gp …]: as contas da página (score-core.js) e as âncoras tiradas do
// desenho do alphaTab no node, como a página faz, nos Guitar Pro de tests/fixtures (feitos pelo conversor do motor)
// ou nos arquivos dados.
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

test("âncoras: no mesmo tique fica a nota, não a barra", () => {
  const anchors = core.cleanAnchors([[3840, 300], [3840, 316], [0, 136], [960, 173], [7680, 480]]);
  assert.deepEqual(anchors, [[0, 136], [960, 173], [3840, 316], [7680, 480]]);
  assert.equal(core.xAtTick(anchors, 480), 154.5);
  assert.equal(core.xAtTick(anchors, -10), 136);
  assert.equal(core.xAtTick(anchors, 99999), 480);
  assert.equal(core.tickAtX(anchors, 154.5), 480);
  assert.equal(core.tickAtX(anchors, 0), 0);
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
    test(`âncoras do alphaTab em ${path.basename(file)}`, () => {
      const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(file)), new alphaTab.Settings());
      const settings = new alphaTab.Settings();
      settings.core.engine = "svg";
      settings.display.layoutMode = alphaTab.LayoutMode.Horizontal;
      settings.display.staveProfile = alphaTab.StaveProfile.Tab;
      const renderer = new alphaTab.rendering.ScoreRenderer(settings);
      renderer.width = 1200;
      renderer.renderScore(score, [0]);
      const raw = [];
      let tick = 0;
      for (const system of renderer.boundsLookup.staffSystems) {
        for (const masterBounds of system.bars) {
          const master = score.masterBars[masterBounds.index];
          // A régua do motor soma as fórmulas de compasso desde zero: o alphaTab tem de concordar.
          assert.equal(master.start, tick);
          tick += master.calculateDuration();
          raw.push([tick, masterBounds.realBounds.x + masterBounds.realBounds.w]);
          for (const bar of masterBounds.bars) {
            for (const beat of bar.beats) {
              raw.push([beat.beat.absolutePlaybackStart, beat.onNotesX]);
            }
          }
        }
      }
      const anchors = core.cleanAnchors(raw);
      for (let i = 1; i < anchors.length; i++) {
        assert.ok(anchors[i][0] > anchors[i - 1][0] && anchors[i][1] >= anchors[i - 1][1]);
      }
      const firstBeat = renderer.boundsLookup.staffSystems[0].bars[1].bars[0].beats[0];
      assert.equal(core.xAtTick(anchors, score.masterBars[1].start), firstBeat.onNotesX);
    });
  }
}
console.log(`${passed} verificações passaram`);
