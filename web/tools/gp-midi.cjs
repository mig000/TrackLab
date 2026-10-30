// node web/tools/gp-midi.cjs <partitura.gp> <saida.mid>: o MIDI do Guitar Pro pelo alphaTab do projeto (o mesmo que
// desenha a TAB), com as articulações que ele sabe tocar (bends, slides, vibrato, abafadas, dinâmica), uma trilha MIDI
// por pista, 960 tiques por semínima (os tiques do mapa de tempo). Escreve no stdout, em JSON, as pistas: índice,
// nome, canais, programa (instrumento General MIDI) e se é bateria. O motor (media/synth.py) troca o andamento do
// Guitar Pro pelo do mapa de tempo e sintetiza cada pista com o FluidSynth.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const alphaTab = require(path.join(__dirname, "..", "vendor", "alphatab", "alphaTab.js"));

const [source, target] = process.argv.slice(2);
if (!source || !target) {
  console.error("uso: node gp-midi.cjs <partitura.gp> <saida.mid>");
  process.exit(2);
}
const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(source)), new alphaTab.Settings());
// O que o Guitar Pro deixou mudo também é gerado: no TrackLab, quem cala é o mixer.
for (const track of score.tracks) {
  track.playbackInfo.isMute = false;
  track.playbackInfo.isSolo = false;
}
const midi = new alphaTab.midi.MidiFile();
midi.format = alphaTab.midi.MidiFileFormat.MultiTrack;
const generator = new alphaTab.midi.MidiFileGenerator(score, new alphaTab.Settings(),
  new alphaTab.midi.AlphaSynthMidiFileHandler(midi, true));
generator.generate();
fs.writeFileSync(target, midi.toBinary());
process.stdout.write(JSON.stringify({
  division: midi.division,
  tracks: score.tracks.map((track, index) => ({
    index,
    name: track.name || `Faixa ${index + 1}`,
    channels: [...new Set([track.playbackInfo.primaryChannel, track.playbackInfo.secondaryChannel])],
    program: track.playbackInfo.program,
    percussion: track.staves.some((staff) => staff.isPercussion),
  })),
}));
