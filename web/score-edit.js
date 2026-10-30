// A edição da TAB sobre o Guitar Pro carregado (o alphaTab `Score` é a verdade; nada é reconstruído): casa, corda,
// altura, apagar, e as articulações do TabLab (`web/tab-core.js`, `applyTechniques`), ligadas e desligadas uma a
// uma na nota (ou na batida, as que o alphaTab guarda na batida). Depois de cada mudança, `refinish` copia a partitura
// pelo JSON do alphaTab, que roda o `score.finish` de novo: ligados, slides e bends ficam ligados à nota seguinte e
// classificados. A mesma cópia serve de passo do Desfazer. Sem DOM: o node testa (tests/check-edit.cjs).
(function (root, factory) {
  const edit = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = edit;
  } else {
    root.trackEdit = edit;
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  const MAX_FRET = 24;

  // As articulações da paleta: chave, grupo (no mesmo grupo, ligar uma desliga as outras) e onde o alphaTab a guarda.
  // Os bends são em quartos de tom (o alphaTab), com o deslocamento de 0 a 60 ao longo da nota, e com o tipo dito:
  // o Guitar Pro 7 guarda até quatro pontos por bend e perde um "Custom" de cinco (o aviso da exportação do TabLab).
  const BENDS = {
    "bend-half": { type: "Bend", points: [[0, 0], [15, 2], [60, 2]] },
    "bend-full": { type: "Bend", points: [[0, 0], [15, 4], [60, 4]] },
    "bend-1.5": { type: "Bend", points: [[0, 0], [15, 6], [60, 6]] },
    "bend-2": { type: "Bend", points: [[0, 0], [15, 8], [60, 8]] },
    "bend-release": { type: "BendRelease", points: [[0, 0], [20, 4], [40, 4], [60, 0]] },
    "prebend": { type: "Prebend", points: [[0, 4], [60, 4]] },
    "prebend-release": { type: "PrebendRelease", points: [[0, 4], [30, 4], [60, 0]] },
  };
  const GROUPS = {
    hammer: "hammer",
    "slide-legato": "slide-out",
    "slide-shift": "slide-out",
    "slide-out-up": "slide-out",
    "slide-out-down": "slide-out",
    "slide-in-below": "slide-in",
    "slide-in-above": "slide-in",
    vibrato: "vibrato",
    "wide-vibrato": "vibrato",
    "palm-mute": "palm-mute",
    dead: "dead",
    "let-ring": "let-ring",
    ghost: "ghost",
    staccato: "staccato",
    accent: "accent",
    "heavy-accent": "accent",
    "harmonic-natural": "harmonic",
    "harmonic-artificial": "harmonic",
    "harmonic-pinch": "harmonic",
    "harmonic-tap": "harmonic",
    "pick-down": "pick",
    "pick-up": "pick",
    tap: "tap",
  };
  for (const key of Object.keys(BENDS)) {
    GROUPS[key] = "bend";
  }
  const HARMONICS = { "harmonic-natural": "Natural", "harmonic-artificial": "Artificial", "harmonic-pinch": "Pinch",
    "harmonic-tap": "Tap" };

  // As chaves ligadas numa nota do alphaTab.
  function techniquesOf(at, note) {
    const m = at.model;
    const on = [];
    const beat = note.beat;
    if (note.isHammerPullOrigin) on.push("hammer");
    if (note.slideOutType === m.SlideOutType.Legato) on.push("slide-legato");
    if (note.slideOutType === m.SlideOutType.Shift) on.push("slide-shift");
    if (note.slideOutType === m.SlideOutType.OutUp) on.push("slide-out-up");
    if (note.slideOutType === m.SlideOutType.OutDown) on.push("slide-out-down");
    if (note.slideInType === m.SlideInType.IntoFromBelow) on.push("slide-in-below");
    if (note.slideInType === m.SlideInType.IntoFromAbove) on.push("slide-in-above");
    if (note.vibrato === m.VibratoType.Slight) on.push("vibrato");
    if (note.vibrato === m.VibratoType.Wide) on.push("wide-vibrato");
    if (note.isPalmMute) on.push("palm-mute");
    if (note.isDead) on.push("dead");
    if (note.isLetRing) on.push("let-ring");
    if (note.isGhost) on.push("ghost");
    if (note.isStaccato) on.push("staccato");
    if (note.accentuated === m.AccentuationType.Normal) on.push("accent");
    if (note.accentuated === m.AccentuationType.Heavy) on.push("heavy-accent");
    for (const [key, name] of Object.entries(HARMONICS)) {
      if (note.harmonicType === m.HarmonicType[name]) on.push(key);
    }
    const bend = bendKey(note);
    if (bend) on.push(bend);
    if (beat && beat.pickStroke === m.PickStroke.Down) on.push("pick-down");
    if (beat && beat.pickStroke === m.PickStroke.Up) on.push("pick-up");
    if (beat && beat.tap) on.push("tap");
    return on;
  }

  // O bend da paleta que a nota tem: pelo tipo e pelo pico (num "Custom" de outro editor, pela forma dos pontos);
  // null sem bend.
  function bendKey(note) {
    const points = note.bendPoints || [];
    if (points.length < 2) {
      return null;
    }
    const values = points.map((p) => p.value);
    const peak = Math.max(...values);
    const first = values[0];
    const last = values[values.length - 1];
    if (first > 0) {
      return last < first ? "prebend-release" : "prebend";
    }
    if (last < peak) {
      return "bend-release";
    }
    return { 2: "bend-half", 4: "bend-full", 6: "bend-1.5", 8: "bend-2" }[peak] || "bend-full";
  }

  // Liga ou desliga uma articulação; no mesmo grupo, ligar troca a que estava. Nota morta não tem bend, vibrato nem
  // harmônico (a regra do TabLab). Devolve se mudou algo.
  function toggle(at, note, key) {
    const group = GROUPS[key];
    if (!group) {
      return false;
    }
    const was = techniquesOf(at, note).includes(key);
    clearGroup(at, note, group);
    if (!was) {
      apply(at, note, key);
      if (key === "dead") {
        for (const other of ["bend", "vibrato", "harmonic"]) clearGroup(at, note, other);
      }
      if (group === "bend" || group === "vibrato" || group === "harmonic") {
        note.isDead = false;
      }
    }
    return true;
  }

  function clearGroup(at, note, group) {
    const m = at.model;
    const beat = note.beat;
    switch (group) {
      case "hammer":
        note.isHammerPullOrigin = false;
        break;
      case "slide-out":
        note.slideOutType = m.SlideOutType.None;
        note.slideTarget = null;
        break;
      case "slide-in":
        note.slideInType = m.SlideInType.None;
        break;
      case "vibrato":
        note.vibrato = m.VibratoType.None;
        break;
      case "bend":
        note.bendPoints = [];
        note.bendType = m.BendType.None;
        note.bendStyle = m.BendStyle.Default;
        break;
      case "harmonic":
        note.harmonicType = m.HarmonicType.None;
        note.harmonicValue = 0;
        break;
      case "accent":
        note.accentuated = m.AccentuationType.None;
        break;
      case "pick":
        if (beat) beat.pickStroke = m.PickStroke.None;
        break;
      case "tap":
        if (beat) beat.tap = false;
        break;
      case "palm-mute":
        note.isPalmMute = false;
        break;
      case "dead":
        note.isDead = false;
        break;
      case "let-ring":
        note.isLetRing = false;
        break;
      case "ghost":
        note.isGhost = false;
        break;
      case "staccato":
        note.isStaccato = false;
        break;
    }
  }

  function apply(at, note, key) {
    const m = at.model;
    const beat = note.beat;
    if (BENDS[key]) {
      for (const [offset, value] of BENDS[key].points) note.addBendPoint(new m.BendPoint(offset, value));
      note.bendType = m.BendType[BENDS[key].type];
      return;
    }
    if (HARMONICS[key]) {
      note.harmonicType = m.HarmonicType[HARMONICS[key]];
      return;
    }
    switch (key) {
      case "hammer":
        // O score.finish liga à próxima nota da corda e decide H ou P pelas casas; sem ela, não fica.
        note.isHammerPullOrigin = true;
        break;
      case "slide-legato":
        note.slideOutType = m.SlideOutType.Legato;
        break;
      case "slide-shift":
        note.slideOutType = m.SlideOutType.Shift;
        break;
      case "slide-out-up":
        note.slideOutType = m.SlideOutType.OutUp;
        break;
      case "slide-out-down":
        note.slideOutType = m.SlideOutType.OutDown;
        break;
      case "slide-in-below":
        note.slideInType = m.SlideInType.IntoFromBelow;
        break;
      case "slide-in-above":
        note.slideInType = m.SlideInType.IntoFromAbove;
        break;
      case "vibrato":
        note.vibrato = m.VibratoType.Slight;
        break;
      case "wide-vibrato":
        note.vibrato = m.VibratoType.Wide;
        break;
      case "palm-mute":
        note.isPalmMute = true;
        break;
      case "dead":
        note.isDead = true;
        break;
      case "let-ring":
        note.isLetRing = true;
        break;
      case "ghost":
        note.isGhost = true;
        break;
      case "staccato":
        note.isStaccato = true;
        break;
      case "accent":
        note.accentuated = m.AccentuationType.Normal;
        break;
      case "heavy-accent":
        note.accentuated = m.AccentuationType.Heavy;
        break;
      case "pick-down":
        beat.pickStroke = m.PickStroke.Down;
        break;
      case "pick-up":
        beat.pickStroke = m.PickStroke.Up;
        break;
      case "tap":
        beat.tap = true;
        break;
    }
  }

  // A corda no TrackLab é 1 na mais aguda; no alphaTab, 1 é a mais grave.
  function tabString(note) {
    const strings = note.beat.voice.bar.staff.tuning.length;
    return strings - note.string + 1;
  }

  function openPitch(staff, alphaString) {
    return staff.tuning[staff.tuning.length - alphaString];
  }

  function stringBusy(beat, alphaString, except) {
    return beat.notes.some((other) => other !== except && other.string === alphaString);
  }

  // A casa da nota (0–24).
  function setFret(note, fret) {
    if (!Number.isInteger(fret) || fret < 0 || fret > MAX_FRET || note.fret === fret) {
      return false;
    }
    note.fret = fret;
    return true;
  }

  // A mesma altura em outra corda (`delta` +1 = uma corda mais aguda): a casa muda pela afinação.
  function moveString(note, delta) {
    const staff = note.beat.voice.bar.staff;
    const target = note.string + delta;
    if (target < 1 || target > staff.tuning.length || stringBusy(note.beat, target, note)) {
      return false;
    }
    const fret = openPitch(staff, note.string) + note.fret - openPitch(staff, target);
    if (fret < 0 || fret > MAX_FRET) {
      return false;
    }
    note.string = target;
    note.fret = fret;
    return true;
  }

  // Meio tom acima ou abaixo na mesma corda.
  function transpose(note, semitones) {
    return setFret(note, note.fret + semitones);
  }

  // Encaixa a nota no som (o "Encaixar" da Lente do TabLab): a altura medida na mesma corda, o bend que o som faz
  // (pontos do Guitar Pro, até quatro: um bend que volta é Bend e volta, senão Bend) e o vibrato, se o som tem.
  // `wanted`: { pitch, bend: [[deslocamento, quartos de tom], …] ou null, vibrato }. Devolve se mudou algo.
  function fit(at, note, wanted) {
    const m = at.model;
    const semitones = Math.round(wanted.pitch) - note.realValue;
    if (semitones !== 0 && !transpose(note, semitones)) {
      return false;
    }
    let changed = semitones !== 0;
    const bend = Array.isArray(wanted.bend) ? wanted.bend.slice(0, 4) : [];
    const before = JSON.stringify((note.bendPoints || []).map((p) => [p.offset, p.value]));
    if (before !== JSON.stringify(bend)) {
      clearGroup(at, note, "bend");
      if (bend.length >= 2) {
        for (const [offset, value] of bend) note.addBendPoint(new m.BendPoint(offset, value));
        const last = bend[bend.length - 1][1];
        note.bendType = last === 0 && bend.length > 2 ? m.BendType.BendRelease : m.BendType.Bend;
        note.isDead = false;
      }
      changed = true;
    }
    const vibrato = wanted.vibrato ? note.vibrato || m.VibratoType.Slight : m.VibratoType.None;
    if (vibrato !== note.vibrato) {
      note.vibrato = vibrato;
      changed = true;
    }
    // O trinado: a outra nota (`trill`, a altura MIDI, na mesma corda) e a figura de cada troca (`trillSpeed`: 8, 16,
    // 32 ou 64; o alphaTab do projeto grava como o Guitar Pro, numa XProperty da nota); sem `trill`, sai.
    const trill = wanted.trill != null && Number.isFinite(wanted.trill) ? Math.round(wanted.trill) : null;
    const fret = trill === null ? -1 : note.fret + trill - note.realValue;
    const value = fret >= 0 && fret <= 30 ? note.stringTuning + fret : -1;
    const speeds = { 8: m.Duration.Eighth, 16: m.Duration.Sixteenth, 32: m.Duration.ThirtySecond, 64: m.Duration.SixtyFourth };
    const speed = speeds[wanted.trillSpeed] || m.Duration.Sixteenth;
    if (value !== note.trillValue || (value >= 0 && speed !== note.trillSpeed)) {
      note.trillValue = value;
      if (value >= 0) note.trillSpeed = speed;
      changed = true;
    }
    return changed;
  }

  // MARK: o tempo das notas
  //
  // A voz 1 de uma pauta vista como uma linha do tempo: cada batida com notas é um intervalo (começo e fim em tiques;
  // uma cadeia de ligaduras vira um intervalo só) e o resto é silêncio. Mudar o tempo de uma nota é mudar o intervalo
  // dela e reescrever os compassos afetados: cada intervalo vira figuras (simples, pontuadas e, se preciso, tercinas),
  // o que passa da barra de compasso vira notas ligadas no compasso seguinte e os espaços viram pausas. A batida
  // original fica no primeiro pedaço (com as articulações dela); os pedaços seguintes são cópias ligadas (casa e corda).

  // Figuras em tiques (960 por semínima): [tiques, duração, pontos, tercina].
  const PLAIN = [[3840, 1, 0], [2880, 2, 1], [1920, 2, 0], [1440, 4, 1], [960, 4, 0], [720, 8, 1], [480, 8, 0],
    [360, 16, 1], [240, 16, 0], [180, 32, 1], [120, 32, 0], [90, 64, 1], [60, 64, 0], [30, 128, 0]];
  const TRIPLETS = [[640, 4, 0], [320, 8, 0], [160, 16, 0], [80, 32, 0]];
  const MIN_TICKS = 30;

  function greedy(length, table) {
    const out = [];
    let left = length;
    while (left > 0) {
      const found = table.find(([ticks]) => ticks <= left);
      if (!found) return null;
      out.push(found);
      left -= found[0];
    }
    return out;
  }

  // As figuras de um trecho: só simples e pontuadas se der; senão com tercinas (3 no tempo de 2).
  function decompose(length) {
    const plain = greedy(length, PLAIN);
    if (plain) return plain.map(([t, d, dots]) => ({ ticks: t, duration: d, dots, triplet: false }));
    const mixed = greedy(length, PLAIN.map((f) => [...f, false]).concat(TRIPLETS.map((f) => [...f, true]))
      .sort((a, b) => b[0] - a[0]));
    return mixed ? mixed.map(([t, d, dots, triplet]) => ({ ticks: t, duration: d, dots, triplet })) : null;
  }

  // O nome de uma duração em tiques, para a prévia do arrasto.
  function figureName(ticks) {
    const names = { 3840: "semibreve", 2880: "mínima pontuada", 1920: "mínima", 1440: "semínima pontuada",
      960: "semínima", 720: "colcheia pontuada", 480: "colcheia", 360: "semicolcheia pontuada", 240: "semicolcheia",
      180: "fusa pontuada", 120: "fusa", 60: "semifusa", 640: "tercina de semínimas", 320: "tercina de colcheias",
      160: "tercina de semicolcheias" };
    return names[Math.round(ticks)] || "notas ligadas";
  }

  function voiceOne(staff) {
    return staff.bars.map((bar) => bar.voices[0]);
  }

  // Os intervalos da voz 1 da pauta, em ordem; as batidas ligadas à anterior (todas as notas) estendem o intervalo dela.
  function timeline(staff) {
    const events = [];
    for (const voice of voiceOne(staff)) {
      for (const beat of voice.beats) {
        if (!beat.notes.length) continue;
        const start = beat.absolutePlaybackStart;
        const end = start + beat.playbackDuration;
        const last = events[events.length - 1];
        if (last && beat.notes.every((n) => n.isTieDestination) && Math.abs(last.end - start) < 1) {
          last.end = end;
          last.tail.push(beat);
          continue;
        }
        events.push({ start, end, beat, tail: [] });
      }
    }
    return events;
  }

  function barAt(staff, tick) {
    const bars = staff.bars;
    for (let i = bars.length - 1; i >= 0; i--) if (bars[i].masterBar.start <= tick + 1e-6) return i;
    return 0;
  }

  function setFigure(at, beat, figure) {
    beat.duration = figure.duration;
    beat.dots = figure.dots;
    beat.tupletNumerator = figure.triplet ? 3 : -1;
    beat.tupletDenominator = figure.triplet ? 2 : -1;
  }

  // Um compasso refeito a partir dos intervalos: pausas nos espaços, o primeiro pedaço de cada intervalo na batida
  // original, os outros em cópias ligadas. Devolve false se um trecho não cabe em figuras.
  function rebuildBar(at, bar, events) {
    const voice = bar.voices[0];
    const from = bar.masterBar.start;
    const to = from + bar.masterBar.calculateDuration();
    const items = [];
    let t = from;
    for (const ev of events) {
      if (ev.start >= to || ev.end <= from) continue;
      const a = Math.max(ev.start, from);
      const b = Math.min(ev.end, to);
      if (a > t) items.push({ length: a - t });
      items.push({ ev, length: b - a, first: ev.start >= from });
      t = b;
    }
    if (t < to) items.push({ length: to - t });
    const beats = [];
    for (const item of items) {
      const figures = decompose(Math.round(item.length));
      if (!figures) return false;
      figures.forEach((figure, i) => {
        let beat;
        if (item.ev && item.first && i === 0) {
          beat = item.ev.beat;
        } else {
          beat = new at.model.Beat();
          if (item.ev) {
            for (const original of item.ev.beat.notes) {
              const copy = new at.model.Note();
              copy.string = original.string;
              copy.fret = original.fret;
              copy.isTieDestination = true;
              beat.addNote(copy);
            }
          }
        }
        setFigure(at, beat, figure);
        beats.push(beat);
      });
    }
    voice.beats = [];
    for (const beat of beats) voice.addBeat(beat);
    return true;
  }

  // A nota (a batida dela, com o acorde) passa a soar de `start` a `end` (tiques). A anterior que passar do começo novo
  // encurta; o fim novo para no começo da seguinte. Devolve true, ou o motivo ("grace", "overlap", "short",
  // "figure", "missing").
  function retime(at, note, start, end) {
    const staff = note.beat.voice.bar.staff;
    const events = timeline(staff);
    const index = events.findIndex((e) => e.beat === note.beat || e.tail.includes(note.beat));
    if (index < 0) return "missing";
    const ev = events[index];
    const previous = events[index - 1];
    const next = events[index + 1];
    start = Math.round(start);
    end = Math.round(end);
    if (start < 0) return "overlap";
    if (next && end > next.start) end = next.start;
    if (end - start < MIN_TICKS) return "short";
    if (previous && start <= previous.start) return "overlap";
    const changed = [ev];
    if (previous && previous.end > start) {
      if (start - previous.start < MIN_TICKS) return "short";
      changed.push(previous);
    }
    const low = Math.min(start, ev.start, ...changed.map((e) => e.start));
    const high = Math.max(end, ev.end);
    const first = barAt(staff, low);
    const last = barAt(staff, high - 1);
    for (let b = first; b <= last; b++) {
      if (staff.bars[b].voices[0].beats.some((x) => x.graceType !== at.model.GraceType.None)) return "grace";
    }
    if (previous && previous.end > start) previous.end = start;
    ev.start = start;
    ev.end = end;
    // Os intervalos refeitos perdem as cópias ligadas de antes (o compasso refeito cria as dele).
    for (let b = first; b <= last; b++) {
      if (!rebuildBar(at, staff.bars[b], events)) return "figure";
    }
    return true;
  }

  // A nota (com as ligadas e o acorde) passa a durar `ticks`, começando no mesmo lugar: mais curta, sobra pausa; mais
  // longa, não passa do começo da seguinte ("next"). Devolve true ou o motivo, como o retime.
  function setLength(at, note, ticks) {
    const events = timeline(note.beat.voice.bar.staff);
    const index = events.findIndex((e) => e.beat === note.beat || e.tail.includes(note.beat));
    if (index < 0) return "missing";
    const ev = events[index];
    const next = events[index + 1];
    const end = ev.start + Math.round(ticks);
    if (next && end > next.start) return "next";
    return retime(at, note, ev.start, end);
  }

  // A nota vira pausa: a batida dela sai (com o acorde e as ligadas) e o espaço fica em pausas.
  function toRest(at, note) {
    const staff = note.beat.voice.bar.staff;
    const events = timeline(staff);
    const index = events.findIndex((e) => e.beat === note.beat || e.tail.includes(note.beat));
    if (index < 0) return "missing";
    const ev = events[index];
    const first = barAt(staff, ev.start);
    const last = barAt(staff, ev.end - 1);
    for (let b = first; b <= last; b++) {
      if (staff.bars[b].voices[0].beats.some((x) => x.graceType !== at.model.GraceType.None)) return "grace";
    }
    events.splice(index, 1);
    for (let b = first; b <= last; b++) {
      if (!rebuildBar(at, staff.bars[b], events)) return "figure";
    }
    return true;
  }

  // A figura de uma duração: a base (semibreve 3840 … fusa 120), com ponto ou em tercina; null se não é uma figura só.
  function rhythmOf(length) {
    const ticks = Math.round(length);
    const plain = PLAIN.find((f) => f[0] === ticks);
    if (plain) return { base: plain[2] ? ticks / 1.5 : ticks, dots: plain[2], triplet: false };
    const triplet = TRIPLETS.find((f) => f[0] === ticks);
    if (triplet) return { base: ticks * 1.5, dots: 0, triplet: true };
    return null;
  }

  // Um passo de `grid` tiques (negativo: antes), mantendo a duração.
  function nudge(at, note, steps, grid) {
    const events = timeline(note.beat.voice.bar.staff);
    const ev = events.find((e) => e.beat === note.beat || e.tail.includes(note.beat));
    if (!ev) return "missing";
    const delta = Math.round(steps) * grid;
    return retime(at, note, ev.start + delta, ev.end + delta);
  }

  // O intervalo da nota (começo e fim em tiques, com as ligaduras).
  function span(note) {
    const ev = timeline(note.beat.voice.bar.staff).find((e) => e.beat === note.beat || e.tail.includes(note.beat));
    return ev ? { start: ev.start, end: ev.end } : null;
  }

  // A nota de uma pista pelo tique em que começa e pela corda (1 é a mais aguda): a que a Fita aponta.
  function findNote(score, track, tick, string) {
    const part = score.tracks[track];
    if (!part) return null;
    for (const staff of part.staves) {
      if (!staff.tuning || !staff.tuning.length) continue;
      const note = notesOf(staff).find((n) => Math.abs(n.beat.absolutePlaybackStart - tick) < 1 && tabString(n) === string);
      if (note) return note;
    }
    return null;
  }

  // Apaga a nota; a batida sem notas vira pausa.
  function remove(note) {
    const notes = note.beat.notes;
    const index = notes.indexOf(note);
    if (index < 0) {
      return false;
    }
    notes.splice(index, 1);
    notes.forEach((other, i) => {
      other.index = i;
    });
    return true;
  }

  // MARK: várias notas de uma vez (⇧ clique, ⌘ clique, ⇧← →)

  // As notas de `a` a `b` (inclusive) na ordem de tempo da pauta; vazio se estão em pautas diferentes.
  function rangeOf(a, b) {
    const staff = a.beat.voice.bar.staff;
    if (b.beat.voice.bar.staff !== staff) return [];
    const list = notesOf(staff);
    const i = list.indexOf(a);
    const j = list.indexOf(b);
    if (i < 0 || j < 0) return [];
    return list.slice(Math.min(i, j), Math.max(i, j) + 1);
  }

  // Uma articulação em várias notas: liga em todas se a principal (a primeira) não tem; senão desliga em todas.
  function toggleAll(at, notes, key) {
    if (!notes.length || !GROUPS[key]) return false;
    const on = techniquesOf(at, notes[0]).includes(key);
    let changed = false;
    for (const note of notes) {
      if (techniquesOf(at, note).includes(key) === on) changed = toggle(at, note, key) || changed;
    }
    return changed;
  }

  // Todas meio tom acima ou abaixo na mesma corda; se uma não pode (fora do braço), nenhuma muda.
  function transposeAll(notes, semitones) {
    if (notes.some((n) => n.fret + semitones < 0 || n.fret + semitones > MAX_FRET)) return false;
    for (const note of notes) setFret(note, note.fret + semitones);
    return true;
  }

  // Todas para outra corda na mesma altura (o trecho noutra posição do braço); as da ponta para onde andam vão primeiro,
  // para uma não ocupar a corda da vizinha de acorde. Se uma não pode, devolve false (quem chama desfaz).
  function moveAll(notes, delta) {
    const sorted = notes.slice().sort((a, b) => (delta > 0 ? b.string - a.string : a.string - b.string));
    for (const note of sorted) {
      if (!moveString(note, delta)) return false;
    }
    return true;
  }

  // As notas de uma pauta em ordem de tempo e, na mesma batida, da corda mais aguda para a mais grave.
  function notesOf(staff) {
    const list = [];
    for (const bar of staff.bars) {
      for (const voice of bar.voices) {
        for (const beat of voice.beats) {
          const sorted = beat.notes.slice().sort((a, b) => b.string - a.string);
          for (const note of sorted) list.push(note);
        }
      }
    }
    return list.sort((a, b) => a.beat.absolutePlaybackStart - b.beat.absolutePlaybackStart || b.string - a.string);
  }

  // A nota seguinte (dir 1) ou anterior (dir −1) da pauta.
  function neighbor(note, dir) {
    const list = notesOf(note.beat.voice.bar.staff);
    const index = list.indexOf(note);
    return index < 0 ? null : list[index + dir] || null;
  }

  // O endereço de uma nota que sobrevive à cópia da partitura: pista, pauta, compasso, voz, batida e corda.
  function pathOf(note) {
    const beat = note.beat;
    const voice = beat.voice;
    const bar = voice.bar;
    const staff = bar.staff;
    return [staff.track.index, staff.index, bar.index, voice.index, beat.index, note.string];
  }

  function resolve(score, path) {
    if (!path) return null;
    const [t, s, b, v, i, string] = path;
    const beat = score.tracks[t] && score.tracks[t].staves[s] && score.tracks[t].staves[s].bars[b] &&
      score.tracks[t].staves[s].bars[b].voices[v] && score.tracks[t].staves[s].bars[b].voices[v].beats[i];
    return beat ? beat.notes.find((n) => n.string === string) || null : null;
  }

  // A partitura de novo pelo JSON do alphaTab, que roda o finish: as ligações e as formas ficam certas.
  function snapshot(at, score) {
    return at.model.JsonConverter.scoreToJsObject(score);
  }

  function restore(at, object) {
    return at.model.JsonConverter.jsObjectToScore(object, new at.Settings());
  }

  function refinish(at, score) {
    return restore(at, snapshot(at, score));
  }

  // O Guitar Pro 7 da partitura (para gravar no pacote).
  function exportGp(at, score) {
    return new at.exporter.Gp7Exporter().export(score, new at.Settings());
  }

  // O que o app mostra da nota escolhida: a pista, a corda (1 é a mais aguda), a casa, a altura e as articulações.
  // A nota escolhida para o app: onde está, a figura da batida e, para cada corda da TAB (1, a mais aguda, primeiro), a
  // casa em que a mesma altura cai nela (null fora do braço ou com a corda ocupada por outra nota da batida).
  function describe(at, note) {
    const staff = note.beat.voice.bar.staff;
    const pitch = openPitch(staff, note.string) + note.fret;
    const strings = [];
    for (let tab = 1; tab <= staff.tuning.length; tab++) {
      const alpha = staff.tuning.length - tab + 1;
      const fret = pitch - openPitch(staff, alpha);
      strings.push(alpha === note.string ? note.fret
        : fret < 0 || fret > MAX_FRET || stringBusy(note.beat, alpha, note) ? null : fret);
    }
    const sounding = span(note);
    const length = sounding ? sounding.end - sounding.start : note.beat.playbackDuration;
    const rhythm = rhythmOf(length);
    return { track: staff.track.index, string: tabString(note), fret: note.fret,
      pitch: note.realValue, tick: note.beat.absolutePlaybackStart, techniques: techniquesOf(at, note),
      figure: figureName(length), length, base: rhythm ? rhythm.base : null, dots: rhythm ? rhythm.dots : 0,
      triplet: rhythm ? rhythm.triplet : false, strings };
  }

  return {
    BENDS,
    GROUPS,
    MAX_FRET,
    describe,
    exportGp,
    findNote,
    fit,
    moveString,
    neighbor,
    notesOf,
    nudge,
    retime,
    rangeOf,
    moveAll,
    rhythmOf,
    setLength,
    span,
    toRest,
    toggleAll,
    transposeAll,
    techniquesOf,
    timeline,
    figureName,
    pathOf,
    refinish,
    remove,
    resolve,
    restore,
    setFret,
    snapshot,
    tabString,
    techniquesOf,
    toggle,
    transpose,
  };
});
