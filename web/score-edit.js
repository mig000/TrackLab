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
  // O Bend é como o do Guitar Pro 8: dois pontos, chega no alto a um quarto da nota e fica (com um terceiro ponto no
  // fim, a gravação reduzia aos das pontas e a subida ia até o fim da nota).
  const BENDS = {
    "bend-half": { type: "Bend", points: [[0, 0], [15, 2]] },
    "bend-full": { type: "Bend", points: [[0, 0], [15, 4]] },
    "bend-1.5": { type: "Bend", points: [[0, 0], [15, 6]] },
    "bend-2": { type: "Bend", points: [[0, 0], [15, 8]] },
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
    if (note.isTieDestination) on.push("tie");
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
    // A ligada que só segura o alto do bend de antes (Hold) não é um pré-bend dela.
    if (note.isTieDestination && values.every((v) => v === first)) {
      return null;
    }
    if (first > 0) {
      return last < first ? "prebend-release" : last > first ? "prebend-bend" : "prebend";
    }
    if (last < peak) {
      return "bend-release";
    }
    // Uma altura sem botão (¼, ¾, 2½…) não é a de um preset: antes aparecia como "1".
    return { 2: "bend-half", 4: "bend-full", 6: "bend-1.5", 8: "bend-2" }[peak] || "bend";
  }

  // Liga ou desliga uma articulação; no mesmo grupo, ligar troca a que estava. Nota morta não tem bend, vibrato nem
  // harmônico (a regra do TabLab). Devolve se mudou algo.
  function toggle(at, note, key) {
    const group = GROUPS[key];
    if (!group) {
      return false;
    }
    // Como o Guitar Pro grava (conferido nele): o P.M. vale para a nota com as ligadas seguintes; o vibrato e o let ring
    // ficam só na nota escolhida (a ligada vibra com ela no som, e a linha do vibrato fica sobre ela).
    const notes = [note];
    if (group === "palm-mute") {
      for (let n = note.tieDestination; n && n.isTieDestination; n = n.tieDestination) notes.push(n);
    }
    const was = techniquesOf(at, note).includes(key);
    for (const n of notes) {
      clearGroup(at, n, group);
      if (!was) {
        apply(at, n, key);
        if (key === "dead") {
          for (const other of ["bend", "vibrato", "harmonic"]) clearGroup(at, n, other);
        }
        if (group === "bend" || group === "vibrato" || group === "harmonic") {
          n.isDead = false;
        }
        // P.M. e let ring não convivem (o Guitar Pro tira um ao pôr o outro; o let ring tira o P.M. das ligadas também).
        if (key === "palm-mute") n.isLetRing = false;
      }
    }
    if (key === "let-ring" && !was) {
      for (let n = note; n; n = n.tieDestination && n.tieDestination.isTieDestination ? n.tieDestination : null) {
        n.isPalmMute = false;
      }
    }
    if (group === "bend") freeFollowers(at, note);
    if (group === "vibrato" && !was) dropHolds(at, note);
    return true;
  }

  // As ligadas com vibrato da cadeia ficam sem o Hold que só segura o alto de antes, com o mesmo som: com ele, o
  // Guitar Pro desenha o pontilhado e o vibrato por cima dele; sem ele, o vibrato sai da ponta da seta. A importação
  // do Songsterr grava o Hold nas ligadas depois de um bend.
  function dropHolds(at, note) {
    let first = note;
    while (first.isTieDestination && first.tieOrigin) first = first.tieOrigin;
    for (let n = first.tieDestination; n && n.isTieDestination; n = n.tieDestination) {
      const own = (n.bendPoints || []).map((p) => p.value);
      if (!n.vibrato || !own.length || own.some((v) => v !== own[0])) continue;
      const before = bendOf(n.tieOrigin);
      if (own[0] === (before.length ? before[before.length - 1][1] : 0)) setBend(at, n, [], true);
    }
  }

  // As ligadas depois de um bend ficam sem bend, como o Guitar Pro grava: elas continuam no alto do bend de antes (a
  // seta segue por elas até uma com vibrato). Um Hold que estivesse nelas sai (com ele, o Guitar Pro desenha o
  // pontilhado e o vibrato por cima dele); a primeira com bend próprio, que sobe ou desce, para a busca.
  function freeFollowers(at, note) {
    for (let n = note.tieDestination; n && n.isTieDestination; n = n.tieDestination) {
      const own = (n.bendPoints || []).map((p) => p.value);
      if (own.length && own.some((v) => v !== own[0])) break;
      if (own.length) setBend(at, n, [], true);
    }
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
      // O Guitar Pro precisa do traste do harmônico (sem ele, o harmônico some ao abrir): o natural soa no traste da
      // casa, e os outros uma oitava acima da nota presa.
      note.harmonicValue = key === "harmonic-natural" ? note.fret : 12;
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
    const chain = chainOf(note);
    if (chain.length > 1 && wanted.trill == null) return fitChain(at, chain, wanted);
    note = chain[0];
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

  // O encaixe numa nota ligada (o app mede a nota inteira): a altura na primeira (as ligadas seguem a casa dela), o
  // bend medido repartido entre as ligadas pelo tempo de cada uma, e o vibrato onde já está escrito (sem nenhum, na
  // última: o vibrato no fim de um bend).
  function fitChain(at, chain, wanted) {
    const m = at.model;
    const head = chain[0];
    const semitones = Math.round(wanted.pitch) - head.realValue;
    if (semitones !== 0 && !transpose(head, semitones)) {
      return false;
    }
    let changed = semitones !== 0;
    for (const n of chain) n.fret = head.fret;
    const bend = Array.isArray(wanted.bend) ? wanted.bend.slice(0, 4) : [];
    const lengths = chain.map((n) => n.beat.playbackDuration);
    const total = lengths.reduce((a, b) => a + b, 0);
    let done = 0;
    chain.forEach((n, i) => {
      const part = i > 0 ? held(bendPart(bend, done / total, (done + lengths[i]) / total))
        : bendPart(bend, done / total, (done + lengths[i]) / total);
      done += lengths[i];
      if (JSON.stringify((n.bendPoints || []).map((p) => [p.offset, p.value])) !== JSON.stringify(part)) {
        setBend(at, n, part, i > 0);
        changed = true;
      }
    });
    if (wanted.vibrato && !chain.some((n) => n.vibrato)) {
      chain[chain.length - 1].vibrato = m.VibratoType.Slight;
      changed = true;
    } else if (!wanted.vibrato && chain.some((n) => n.vibrato)) {
      for (const n of chain) n.vibrato = m.VibratoType.None;
      changed = true;
    }
    if (head.trillValue >= 0) {
      head.trillValue = -1;
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

  function voiceAt(staff, v) {
    return staff.bars.map((bar) => bar.voices[v]).filter(Boolean);
  }

  // Os intervalos de uma voz da pauta (`v`: 0 é a voz 1), em ordem; as batidas ligadas à anterior (todas as notas)
  // estendem o intervalo dela.
  function timeline(staff, v = 0) {
    const events = [];
    for (const voice of voiceAt(staff, v)) {
      for (const beat of voice.beats) {
        if (!beat.notes.length) continue;
        const start = beat.absolutePlaybackStart;
        const end = start + beat.playbackDuration;
        const last = events[events.length - 1];
        // A batida continua a anterior só se todas as cordas dela seguem ligadas: num acorde em que só uma nota segue,
        // juntar as duas esticava as outras notas do acorde até o fim da ligada.
        const piece = last && (last.tail.length ? last.tail[last.tail.length - 1] : last.beat);
        const same = piece && piece.notes.length === beat.notes.length
          && beat.notes.every((n) => n.isTieDestination && piece.notes.some((p) => p.string === n.string));
        if (last && same && Math.abs(last.end - start) < 1) {
          last.end = end;
          last.tail.push(beat);
          continue;
        }
        events.push({ start, end, beat, tail: [], from: start });
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

  // Se algum compasso de `first` a `last` tem apojatura na voz `v` (esses não são refeitos).
  function hasGrace(at, staff, first, last, v) {
    for (let b = first; b <= last; b++) {
      const voice = staff.bars[b].voices[v];
      if (voice && voice.beats.some((x) => x.graceType !== at.model.GraceType.None)) return true;
    }
    return false;
  }

  // Uma cópia ligada da nota: a casa e a corda; com `full`, também o que a ligada tem de seu (o vibrato, o bend
  // segurado), sem o que é do ataque ou leva à nota seguinte (slides, ligado, acento).
  function tieCopy(at, original, full) {
    const m = at.model;
    const copy = new m.Note();
    if (full) {
      Object.assign(copy, plain(original));
      for (const p of original.bendPoints || []) copy.addBendPoint(new m.BendPoint(p.offset, p.value));
      copy.slideInType = m.SlideInType.None;
      copy.slideOutType = m.SlideOutType.None;
      copy.isHammerPullOrigin = false;
      copy.accentuated = m.AccentuationType.None;
    }
    copy.string = original.string;
    copy.fret = original.fret;
    copy.isTieDestination = true;
    return copy;
  }

  // Onde uma nota ligada muda de articulação (a ligada com vibrato depois do bend, o bend segurado): o compasso refeito
  // corta ali, na mesma distância do começo da nota, e reaproveita a batida. `ev.breaks` dá os cortes à mão (o split).
  function breaksOf(at, ev) {
    if (!ev.breaks) {
      const from = ev.from === undefined ? ev.start : ev.from;
      const own = (n) => techniquesOf(at, n).some((k) => k !== "tie") || (n.bendPoints || []).length > 0;
      ev.breaks = (ev.tail || []).filter((b) => b.notes.some(own))
        .map((b) => ({ tick: ev.start + b.absolutePlaybackStart - from, beat: b }));
    }
    return ev.breaks.filter((x) => x.tick > ev.start && x.tick < ev.end);
  }

  // O bend (quartos de tom) no deslocamento `x` (0 a 60) pelos pontos [[deslocamento, valor], …].
  function bendAt(points, x) {
    if (x <= points[0][0]) return points[0][1];
    for (let i = 1; i < points.length; i++) {
      const [x0, y0] = points[i - 1];
      const [x1, y1] = points[i];
      if (x <= x1) return x1 > x0 ? y0 + ((y1 - y0) * (x - x0)) / (x1 - x0) : y1;
    }
    return points[points.length - 1][1];
  }

  // O trecho de `a` a `b` (frações da nota, 0 a 1) de um bend, nos 0 a 60 do trecho: as pontas interpoladas, os
  // pontos de dentro, sem os do meio de um trecho reto, até quatro (o Guitar Pro 7 perde um bend de cinco). Vazio sem
  // bend no trecho.
  function bendPart(points, a, b) {
    if (!points.length || b <= a) return [];
    const xa = a * 60;
    const xb = b * 60;
    let out = [[xa, bendAt(points, xa)], ...points.filter(([x]) => x > xa && x < xb), [xb, bendAt(points, xb)]]
      .map(([x, y]) => [Math.round(((x - xa) / (xb - xa)) * 60), Math.round(y)]);
    out = out.filter((p, i) => i === 0 || i === out.length - 1 || p[1] !== out[i - 1][1] || p[1] !== out[i + 1][1]);
    // Parado antes de subir ou depois de chegar fica implícito, como o Guitar Pro 7 guarda (um Bend de três pontos ele
    // reduz aos das pontas, e a subida esticava até o fim da nota).
    while (out.length > 2 && out[0][1] === out[1][1]) out.shift();
    while (out.length > 2 && out[out.length - 1][1] === out[out.length - 2][1]) out.pop();
    while (out.length > 4) {
      // Sai o ponto de dentro que menos se afasta da reta entre os vizinhos.
      let worst = 1;
      let least = Infinity;
      for (let i = 1; i < out.length - 1; i++) {
        const [x0, y0] = out[i - 1];
        const [x1, y1] = out[i + 1];
        const line = x1 > x0 ? y0 + ((y1 - y0) * (out[i][0] - x0)) / (x1 - x0) : y0;
        if (Math.abs(out[i][1] - line) < least) {
          least = Math.abs(out[i][1] - line);
          worst = i;
        }
      }
      out.splice(worst, 1);
    }
    return out.some((p) => p[1] !== 0) ? out : [];
  }

  // O bend de cada corda de uma nota (com as ligadas), em frações da nota inteira como ela era (0 a 60 = do começo ao
  // fim dela; uma ligada sem pontos segura o alto da de antes). Guardado antes de o compasso ser refeito: as partes novas
  // recebem o mesmo som no mesmo tempo (`keepBend`). Antes os pontos ficavam relativos à parte, e juntar as ligadas numa
  // figura maior esticava a subida (o bend de uma semínima ligada à mínima subia em uma semínima, e não em 1/16).
  function curvesOf(ev) {
    if (ev.curves) return ev.curves;
    const pieces = [ev.beat, ...(ev.tail || [])];
    // Uma batida nova (colada, posta no meio de outra) ainda não tem duração: vale a que ela trouxe (as partes de uma
    // nota ligada colada) ou a do intervalo.
    const lengths = pieces.map((beat) => beat.playbackDuration || beat.tracklabLength || 0);
    if (!(lengths.every((x) => x > 0))) lengths.splice(0, lengths.length, ...pieces.map(() => (ev.end - ev.start) / pieces.length));
    const total = lengths.reduce((sum, x) => sum + x, 0);
    const curves = new Map();
    let t = 0;
    for (const [index, beat] of pieces.entries()) {
      const length = lengths[index];
      for (const note of beat.notes) {
        const curve = curves.get(note.string) || { points: [], held: 0, bent: false };
        const own = note.bendPoints || [];
        if (own.length) {
          for (const p of own) curve.points.push([((t + (p.offset / 60) * length) / total) * 60, p.value]);
          curve.held = own[own.length - 1].value;
          curve.bent = true;
        } else if (curve.held > 0) {
          curve.points.push([(t / total) * 60, curve.held], [((t + length) / total) * 60, curve.held]);
        }
        curves.set(note.string, curve);
      }
      t += length;
    }
    ev.curves = curves;
    ev.total = total;
    return curves;
  }

  // A parte da nota que começa `offset` tiques depois do começo dela e dura `length`: o bend de cada corda no tempo dela
  // (a primeira parte com o tipo dele; as ligadas que só seguram o alto, sem bend, como o Guitar Pro grava).
  function keepBend(at, ev, beat, offset, length) {
    const curves = curvesOf(ev);
    for (const note of beat.notes) {
      const curve = curves.get(note.string);
      if (!curve || !curve.bent) continue;
      const part = bendPart(curve.points, offset / ev.total, (offset + length) / ev.total);
      setBend(at, note, offset === 0 ? part : held(part), offset > 0);
    }
  }

  // Uma parte ligada que só fica no alto do bend de antes não leva bend (o Guitar Pro grava assim).
  function held(points) {
    return points.every((p) => p[1] === (points[0] || [0, 0])[1]) ? [] : points;
  }

  // Os pontos do bend na nota, com o tipo pela forma; `tied`: uma ligada que fica no alto é Hold.
  function setBend(at, note, points, tied) {
    const m = at.model;
    clearGroup(at, note, "bend");
    if (points.length < 2) return;
    for (const [x, y] of points) note.addBendPoint(new m.BendPoint(x, y));
    const first = points[0][1];
    const last = points[points.length - 1][1];
    note.bendType = points.every((p) => p[1] === first) ? (tied ? m.BendType.Hold : m.BendType.Prebend)
      : first > 0 ? (last < first ? m.BendType.PrebendRelease : m.BendType.PrebendBend)
      : last === 0 ? m.BendType.BendRelease : m.BendType.Bend;
  }

  // O bend do editor da coluna (`BendForm` no app): os pontos [deslocamento 0–60, quartos de tom 0–12], de dois a
  // quatro, em ordem dentro da nota (o Guitar Pro 7 guarda até quatro); vazio tira o bend. As ligadas seguintes que só
  // seguravam o alto de antes ficam livres, como no toggle. Devolve false se os pontos não cabem no formato.
  function setBendPoints(at, note, points) {
    if (!Array.isArray(points)) return false;
    const clean = points.map((p) => (Array.isArray(p) ? [Number(p[0]), Number(p[1])] : [NaN, NaN]));
    if (clean.length === 1 || clean.length > 4) return false;
    if (clean.some(([x, y]) => !(x >= 0 && x <= 60) || !(y >= 0 && y <= 12))) return false;
    if (clean.some(([x], i) => i > 0 && x < clean[i - 1][0])) return false;
    setBend(at, note, clean, note.isTieDestination);
    if (clean.length) note.isDead = false;
    freeFollowers(at, note);
    return true;
  }

  // Os bends de mais de quatro pontos (de outro editor) reduzidos aos quatro que mais pesam, antes de gravar: o
  // exportador do Guitar Pro 7 os jogava fora em silêncio. Devolve quantos.
  function gpSafe(at, score) {
    let count = 0;
    for (const track of score.tracks) for (const staff of track.staves) for (const bar of staff.bars) {
      for (const voice of bar.voices) for (const beat of voice.beats) for (const note of beat.notes) {
        if (!note.bendPoints || note.bendPoints.length <= 4) continue;
        setBend(at, note, bendPart(note.bendPoints.map((p) => [p.offset, p.value]), 0, 1), note.isTieDestination);
        count += 1;
      }
    }
    return count;
  }

  // Os pontos do bend de uma nota ligada: os dela, ou o alto em que a anterior deixou a corda (uma ligada sem pontos
  // segura o bend de antes).
  function bendOf(note) {
    if (note.bendPoints && note.bendPoints.length) return note.bendPoints.map((p) => [p.offset, p.value]);
    for (let n = note.tieOrigin; n; n = n.tieOrigin) {
      if (n.bendPoints && n.bendPoints.length) {
        const top = n.bendPoints[n.bendPoints.length - 1].value;
        return top > 0 ? [[0, top], [60, top]] : [];
      }
    }
    return [];
  }

  // A nota (a batida dela, com o acorde) dividida em duas ligadas no tique `tick`, sem mudar o som: o bend se reparte
  // entre as duas (a segunda segura no alto), a segunda continua o vibrato, o let ring, o P.M. e o harmônico, e leva o
  // slide e o ligado para a nota seguinte se é a última. As outras ligadas ficam onde estão. Devolve true ou o motivo
  // ("short", "same", "grace", "figure", "missing").
  function split(at, note, tick) {
    const m = at.model;
    const staff = note.beat.voice.bar.staff;
    const v = note.beat.voice.index;
    const events = timeline(staff, v);
    const ev = events.find((e) => e.beat === note.beat || e.tail.includes(note.beat));
    if (!ev) return "missing";
    tick = Math.round(tick);
    if (tick - ev.start < MIN_TICKS || ev.end - tick < MIN_TICKS) return "short";
    const pieces = [ev.beat, ...ev.tail];
    if (pieces.some((b) => Math.abs(b.absolutePlaybackStart - tick) < 1)) return "same";
    // O bend da nota inteira, antes de mexer nas partes: o compasso refeito o reparte pelo tempo.
    curvesOf(ev);
    const first = barAt(staff, ev.start);
    const last = barAt(staff, ev.end - 1);
    if (hasGrace(at, staff, first, last, v)) return "grace";
    // O pedaço que soa no tique fica com o começo; a batida nova, com o resto.
    const piece = pieces.filter((b) => b.absolutePlaybackStart < tick).pop();
    const cut = (tick - piece.absolutePlaybackStart) / piece.playbackDuration;
    const ending = piece === pieces[pieces.length - 1];
    const beat = new m.Beat();
    for (const original of piece.notes) {
      const copy = tieCopy(at, original, piece !== ev.beat);
      copy.vibrato = original.vibrato;
      copy.isPalmMute = original.isPalmMute;
      copy.isLetRing = original.isLetRing;
      copy.harmonicType = original.harmonicType;
      copy.harmonicValue = original.harmonicValue;
      const points = bendOf(original);
      setBend(at, original, bendPart(points, 0, cut), piece !== ev.beat);
      setBend(at, copy, held(bendPart(points, cut, 1)), true);
      if (ending) {
        copy.slideOutType = original.slideOutType;
        copy.isHammerPullOrigin = original.isHammerPullOrigin;
        clearGroup(at, original, "slide-out");
        clearGroup(at, original, "hammer");
      }
      beat.addNote(copy);
    }
    // Os cortes de agora ficam (cada ligada com a sua batida), mais o novo.
    ev.breaks = [...ev.tail.map((b) => ({ tick: b.absolutePlaybackStart, beat: b })), { tick, beat }]
      .sort((a, b) => a.tick - b.tick);
    for (let b = first; b <= last; b++) {
      if (!rebuildBar(at, staff.bars[b], events, v)) return "figure";
    }
    return true;
  }

  // L: a nota passa a ser ligada à da batida anterior na mesma corda (continua o som dela, sem atacar: a casa dela e o
  // alto do bend, segurado) ou deixa de ser (ataca de novo). Devolve true ou o motivo ("tie": sem nota antes na corda).
  function tie(at, note) {
    const m = at.model;
    if (note.isTieDestination) {
      note.isTieDestination = false;
      if (note.bendType === m.BendType.Hold) note.bendType = m.BendType.Prebend;
      return true;
    }
    const before = note.beat.previousBeat;
    const previous = before ? before.notes.find((n) => n.string === note.string) : null;
    if (!previous) return "tie";
    note.isTieDestination = true;
    note.fret = previous.fret;
    // Sem bend: a ligada continua no alto do bend de antes, como o Guitar Pro grava.
    if (note.bendType === m.BendType.Hold) setBend(at, note, [], true);
    return true;
  }

  // As notas de uma nota ligada, da primeira à última (a cadeia de ligaduras na corda).
  function chainOf(note) {
    let head = note;
    while (head.tieOrigin && head.isTieDestination) head = head.tieOrigin;
    const chain = [head];
    for (let n = head.tieDestination; n && n.isTieDestination; n = n.tieDestination) chain.push(n);
    return chain;
  }

  // Um compasso refeito a partir dos intervalos da voz `v`: pausas nos espaços, o primeiro pedaço de cada intervalo na
  // batida original, os outros em cópias ligadas. Uma voz além da 1 sem nota no compasso fica vazia (sem pausas à
  // vista). Devolve false se um trecho não cabe em figuras.
  function rebuildBar(at, bar, events, v = 0) {
    while (bar.voices.length <= v) bar.addVoice(new at.model.Voice());
    const voice = bar.voices[v];
    const from = bar.masterBar.start;
    const to = from + bar.masterBar.calculateDuration();
    const items = [];
    let t = from;
    for (const ev of events) {
      if (ev.start >= to || ev.end <= from) continue;
      const a = Math.max(ev.start, from);
      const b = Math.min(ev.end, to);
      if (a > t) items.push({ length: a - t });
      // O pedaço do compasso, cortado onde a ligada muda de articulação: cada parte reaproveita a batida que começa
      // nela (a original, ou a ligada dividida) e as outras partes são cópias ligadas da que soa ali.
      const breaks = breaksOf(at, ev);
      const before = breaks.filter((x) => x.tick <= a).pop();
      let start = a;
      let source = before ? before.beat : ev.beat;
      let reuse = ev.start >= from && a === ev.start ? ev.beat : before && before.tick === a ? before.beat : null;
      curvesOf(ev);
      for (const cut of breaks.filter((x) => x.tick > a && x.tick < b)) {
        items.push({ ev, length: cut.tick - start, reuse, source, pos: start });
        start = cut.tick;
        source = cut.beat;
        reuse = cut.beat;
      }
      items.push({ ev, length: b - start, reuse, source, pos: start });
      t = b;
    }
    if (t < to) items.push({ length: to - t });
    if (v > 0 && !items.some((item) => item.ev)) {
      const empty = new at.model.Beat();
      empty.isEmpty = true;
      empty.duration = at.model.Duration.Whole;
      voice.beats = [];
      voice.addBeat(empty);
      return true;
    }
    const beats = [];
    for (const item of items) {
      const figures = decompose(Math.round(item.length));
      if (!figures) return false;
      let pos = item.pos;
      figures.forEach((figure, i) => {
        let beat;
        if (item.reuse && i === 0) {
          beat = item.reuse;
        } else {
          beat = new at.model.Beat();
          if (item.ev) {
            for (const original of item.source.notes) beat.addNote(tieCopy(at, original, item.source !== item.ev.beat));
          }
        }
        setFigure(at, beat, figure);
        if (item.ev) keepBend(at, item.ev, beat, pos - item.ev.start, figure.ticks);
        pos += figure.ticks;
        beats.push(beat);
      });
    }
    voice.beats = [];
    for (const beat of beats) voice.addBeat(beat);
    return true;
  }

  // Onde a música acaba (tiques): o fim do último compasso.
  function songEnd(staff) {
    const last = staff.bars[staff.bars.length - 1].masterBar;
    return last.start + last.calculateDuration();
  }

  // A nota (a batida dela, com o acorde) passa a soar de `start` a `end` (tiques). A anterior que passar do começo novo
  // encurta; o fim novo para no começo da seguinte e não passa do fim da música (a última nota, levada para depois dele,
  // sumia no compasso refeito). Devolve true, ou o motivo ("grace", "overlap", "short", "end", "figure", "missing").
  function retime(at, note, start, end) {
    const staff = note.beat.voice.bar.staff;
    const v = note.beat.voice.index;
    const events = timeline(staff, v);
    const index = events.findIndex((e) => e.beat === note.beat || e.tail.includes(note.beat));
    if (index < 0) return "missing";
    const ev = events[index];
    const previous = events[index - 1];
    const next = events[index + 1];
    start = Math.round(start);
    end = Math.round(end);
    if (start < 0) return "overlap";
    if (next && end > next.start) end = next.start;
    if (end > songEnd(staff) + 0.5) return "end";
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
    if (hasGrace(at, staff, first, last, v)) return "grace";
    if (previous && previous.end > start) previous.end = start;
    ev.start = start;
    ev.end = end;
    // Os intervalos refeitos perdem as cópias ligadas de antes (o compasso refeito cria as dele).
    for (let b = first; b <= last; b++) {
      if (!rebuildBar(at, staff.bars[b], events, v)) return "figure";
    }
    return true;
  }

  // A nota (com as ligadas e o acorde) passa a durar `ticks`, começando no mesmo lugar: mais curta, sobra pausa; mais
  // longa, não passa do começo da seguinte ("next"). Devolve true ou o motivo, como o retime.
  function setLength(at, note, ticks) {
    const events = timeline(note.beat.voice.bar.staff, note.beat.voice.index);
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
    const v = note.beat.voice.index;
    const events = timeline(staff, v);
    const index = events.findIndex((e) => e.beat === note.beat || e.tail.includes(note.beat));
    if (index < 0) return "missing";
    const ev = events[index];
    const first = barAt(staff, ev.start);
    const last = barAt(staff, ev.end - 1);
    if (hasGrace(at, staff, first, last, v)) return "grace";
    events.splice(index, 1);
    for (let b = first; b <= last; b++) {
      if (!rebuildBar(at, staff.bars[b], events, v)) return "figure";
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
    const events = timeline(note.beat.voice.bar.staff, note.beat.voice.index);
    const ev = events.find((e) => e.beat === note.beat || e.tail.includes(note.beat));
    if (!ev) return "missing";
    const delta = Math.round(steps) * grid;
    return retime(at, note, ev.start + delta, ev.end + delta);
  }

  // O intervalo da nota (começo e fim em tiques, com as ligaduras).
  function span(note) {
    const ev = timeline(note.beat.voice.bar.staff, note.beat.voice.index)
      .find((e) => e.beat === note.beat || e.tail.includes(note.beat));
    return ev ? { start: ev.start, end: ev.end } : null;
  }

  // A nota de uma pista pelo tique em que começa e pela corda (1 é a mais aguda): a que a Fita aponta. Com `voice`, só
  // nessa voz (a voz 1 e a 2 podem ter nota no mesmo tique e na mesma corda).
  function findNote(score, track, tick, string, voice) {
    const part = score.tracks[track];
    if (!part) return null;
    for (const staff of part.staves) {
      if (!staff.tuning || !staff.tuning.length) continue;
      const note = notesOf(staff).find((n) => Math.abs(n.beat.absolutePlaybackStart - tick) < 1 && tabString(n) === string
        && (voice === undefined || voice === null || n.beat.voice.index === voice));
      if (note) return note;
    }
    return null;
  }

  // Apaga a nota; a batida sem notas vira pausa. A ligada que continuava a nota passa a atacar: sem a origem, o finish a
  // prendia à nota anterior da corda (atravessando a pausa) e trocava a casa dela pela daquela nota.
  function remove(note, at) {
    const notes = note.beat.notes;
    const index = notes.indexOf(note);
    if (index < 0) {
      return false;
    }
    const next = note.tieDestination;
    if (next && next.isTieDestination) {
      next.isTieDestination = false;
      if (at && next.bendType === at.model.BendType.Hold) next.bendType = at.model.BendType.Prebend;
    }
    // O do alphaTab tira a nota também da busca por corda (que acha a origem de uma ligadura).
    note.beat.removeNote(note);
    notes.forEach((other, i) => {
      other.index = i;
    });
    return true;
  }

  // MARK: copiar e colar

  // As propriedades que não vão no recorte: endereço e tempo (o compasso refeito dá a figura e o lugar), e as calculadas.
  const SKIP = new Set(["id", "index", "duration", "dots", "tupletNumerator", "tupletDenominator", "graceType",
    "graceIndex", "playbackStart", "displayStart", "playbackDuration", "displayDuration", "isEmpty", "isTieDestination",
    "isContinuedBend", "isContinuedWhammy"]);

  // Os valores simples de um objeto do alphaTab (números, sim e não, textos); as ligações com outras notas e batidas
  // ficam de fora (o finish as refaz).
  function plain(object) {
    const out = {};
    for (const key of Object.keys(object)) {
      const value = object[key];
      if (SKIP.has(key) || key.startsWith("_")) continue;
      if (typeof value === "number" || typeof value === "boolean" || typeof value === "string") out[key] = value;
    }
    return out;
  }

  // As notas que o recorte de `notes` leva: as da pauta da primeira (de qualquer voz). Recortar só deixa pausa nelas.
  function copied(notes) {
    if (!notes.length) return [];
    const staff = notes[0].beat.voice.bar.staff;
    return notes.filter((n) => n.beat.voice.bar.staff === staff);
  }

  // O recorte das notas: o trecho do começo da primeira ao fim da última (com as ligadas), cada batida com todas as notas
  // dela (o acorde inteiro) e as pausas no meio, em cada voz que tem nota escolhida (com duas, cada batida diz a voz,
  // `voice`, e `voices` lista as do recorte). Só valores simples: vai ao app e serve noutra música.
  function copy(notes) {
    const mine = copied(notes);
    if (!mine.length) return null;
    const staff = mine[0].beat.voice.bar.staff;
    const voices = [...new Set(mine.map((n) => n.beat.voice.index))].sort((a, b) => a - b);
    const lines = voices.map((v) => ({ v, events: timeline(staff, v) }));
    const chosen = lines.flatMap(({ events }) => events.filter((e) => mine.some((n) => e.beat === n.beat || e.tail.includes(n.beat))));
    if (!chosen.length) return null;
    const start = Math.min(...chosen.map((e) => e.start));
    const end = Math.max(...chosen.map((e) => e.end));
    const clip = { length: end - start, events: [] };
    if (voices.length > 1) clip.voices = voices;
    const beatData = (beat) => Object.assign(plain(beat), {
      whammy: beat.whammyBarPoints ? beat.whammyBarPoints.map((p) => [p.offset, p.value]) : null });
    const notesData = (beat) => beat.notes.map((n) => Object.assign(plain(n), {
      bend: n.bendPoints ? n.bendPoints.map((p) => [p.offset, p.value]) : null }));
    for (const { v, events } of lines) for (const ev of events) {
      if (ev.start < start || ev.start >= end) continue;
      const item = {
        offset: ev.start - start,
        length: Math.min(ev.end, end) - ev.start,
        beat: beatData(ev.beat),
        notes: notesData(ev.beat),
      };
      if (clip.voices) item.voice = v;
      // Uma nota ligada leva as partes como estão (cada uma com a duração, o bend dela e o vibrato da ligada): colada,
      // soa igual; antes saía uma nota só, sem o que as ligadas tinham, e com a subida do bend esticada.
      if (ev.tail.length) {
        item.parts = [ev.beat, ...ev.tail].map((beat) => ({ offset: beat.absolutePlaybackStart - ev.start,
          length: beat.playbackDuration, beat: beatData(beat), notes: notesData(beat) }));
      }
      clip.events.push(item);
    }
    return clip;
  }

  // Uma batida nova de um recorte, com as notas que cabem nas cordas da pauta.
  function beatFrom(at, staff, item) {
    const m = at.model;
    const beat = new m.Beat();
    const { whammy, ...props } = item.beat;
    Object.assign(beat, props);
    if (whammy) for (const [offset, value] of whammy) beat.addWhammyBarPoint(new m.BendPoint(offset, value));
    for (const data of item.notes) {
      if (data.string < 1 || data.string > staff.tuning.length) continue;
      const { bend, ...rest } = data;
      const note = new m.Note();
      Object.assign(note, rest);
      if (bend) for (const [offset, value] of bend) note.addBendPoint(new m.BendPoint(offset, value));
      beat.addNote(note);
    }
    return beat;
  }

  // Cola o recorte a partir do tique `start` da pauta, por cima do que estava, na voz `v` (um recorte de duas vozes vai
  // cada uma na sua): o que começa no trecho sai, o que vem de antes encurta até ele, e os compassos são refeitos com
  // figuras, pausas e ligaduras. Devolve true ou o motivo ("end": passa do fim da música; "grace", "figure" como o
  // retime).
  function paste(at, staff, start, clip, v = 0) {
    if (!clip || !clip.events) return "missing";
    if (Array.isArray(clip.voices) && clip.voices.length > 1) {
      for (const voice of clip.voices) {
        const result = pasteVoice(at, staff, start, { length: clip.length,
          events: clip.events.filter((item) => item.voice === voice) }, voice);
        if (result !== true) return result;
      }
      return true;
    }
    return pasteVoice(at, staff, start, clip, v);
  }

  function pasteVoice(at, staff, start, clip, v) {
    start = Math.round(start);
    const end = start + Math.round(clip.length);
    const bars = staff.bars;
    if (end > songEnd(staff) + 0.5) return "end";
    const events = timeline(staff, v);
    let low = start;
    let high = end;
    const kept = [];
    for (const ev of events) {
      if (ev.end <= start || ev.start >= end) {
        kept.push(ev);
      } else if (ev.start < start) {
        low = Math.min(low, ev.start);
        high = Math.max(high, ev.end);
        // Encurta com as ligadas: o compasso refeito mantém o que elas têm (o vibrato da ligada) e o bend no tempo.
        kept.push({ ...ev, end: start });
      } else {
        high = Math.max(high, ev.end);
      }
    }
    for (const item of clip.events) {
      const at0 = start + Math.round(item.offset);
      const ev = { start: at0, end: at0 + Math.round(item.length), beat: beatFrom(at, staff, item), tail: [] };
      if (item.parts && item.parts.length > 1) {
        // As partes da nota ligada: cada uma no seu lugar, ligada à anterior, e o bend repartido pelo tempo delas.
        const parts = item.parts.filter((part) => part.offset < item.length);
        ev.beat = beatFrom(at, staff, parts[0]);
        ev.beat.tracklabLength = parts[0].length;
        ev.tail = parts.slice(1).map((part) => {
          const beat = beatFrom(at, staff, part);
          for (const note of beat.notes) note.isTieDestination = true;
          beat.tracklabLength = part.length;
          return beat;
        });
        ev.breaks = ev.tail.map((beat, i) => ({ tick: at0 + Math.round(parts[i + 1].offset), beat }));
      }
      kept.push(ev);
    }
    kept.sort((a, b) => a.start - b.start);
    const first = barAt(staff, low);
    const last = barAt(staff, high - 1);
    if (hasGrace(at, staff, first, last, v)) return "grace";
    for (let b = first; b <= last; b++) {
      if (!rebuildBar(at, bars[b], kept, v)) return "figure";
    }
    return true;
  }

  // MARK: compassos (em todas as pistas)

  // Notas da primeira batida de cada voz do compasso `index` (na cópia JSON) deixam de ser ligadas à anterior: o
  // compasso de antes mudou (um compasso posto, apagado ou com outra fórmula) e a ligadura ficaria sem origem.
  function untieStart(obj, index) {
    for (const track of obj.get("tracks")) {
      for (const staff of track.get("staves")) {
        const bar = staff.get("bars")[index];
        if (!bar) continue;
        for (const voice of bar.get("voices")) {
          const first = voice.get("beats")[0];
          for (const note of first ? first.get("notes") || [] : []) note.set("istiedestination", false);
        }
      }
    }
  }

  // Um compasso novo antes do compasso `index` (no fim, se `index` é o número de compassos), com a fórmula e a
  // armadura do vizinho e pausas em todas as pautas. Devolve { score, tick, oldLength: 0, newLength } (a partitura é
  // outra: quem chama troca).
  function insertBar(at, score, index) {
    const masters = score.masterBars;
    index = Math.max(0, Math.min(Math.round(index), masters.length));
    const ref = masters[Math.min(index, masters.length - 1)];
    const tick = index < masters.length ? masters[index].start : ref.start + ref.calculateDuration();
    const obj = snapshot(at, score);
    const jsMasters = obj.get("masterbars");
    const master = new Map(jsMasters[Math.min(index, jsMasters.length - 1)]);
    master.set("tempoautomations", []);
    master.set("isrepeatstart", false);
    master.set("repeatcount", 0);
    master.set("alternateendings", 0);
    master.set("isanacrusis", false);
    master.delete("section");
    jsMasters.splice(index, 0, master);
    for (const track of obj.get("tracks")) {
      for (const staff of track.get("staves")) {
        const bars = staff.get("bars");
        const refBar = bars[Math.min(index, bars.length - 1)];
        const bar = new Map(refBar);
        for (const key of ["id", "barlineleft", "barlineright", "similemark", "sustainpedals"]) bar.delete(key);
        bar.set("voices", refBar.get("voices").map((_, v) =>
          new Map([["beats", [new Map([["notes", []], ["isempty", v > 0], ["duration", at.model.Duration.Whole]])]]])));
        bars.splice(index, 0, bar);
      }
    }
    untieStart(obj, index + 1);
    const fresh = restore(at, obj);
    // As pausas certas na voz 1 (a fórmula pode não ser 4/4).
    for (const track of fresh.tracks) {
      for (const staff of track.staves) {
        if (!rebuildBar(at, staff.bars[index], [], 0)) return "figure";
      }
    }
    return { score: refinish(at, fresh), tick, oldLength: 0, newLength: fresh.masterBars[index].calculateDuration() };
  }

  // Apaga o compasso `index` de todas as pistas. Devolve { score, tick, oldLength, newLength: 0 }, ou "last" (a
  // música não fica sem compasso).
  function deleteBar(at, score, index) {
    const masters = score.masterBars;
    if (masters.length < 2) return "last";
    index = Math.max(0, Math.min(Math.round(index), masters.length - 1));
    const tick = masters[index].start;
    const oldLength = masters[index].calculateDuration();
    const obj = snapshot(at, score);
    obj.get("masterbars").splice(index, 1);
    for (const track of obj.get("tracks")) {
      for (const staff of track.get("staves")) staff.get("bars").splice(index, 1);
    }
    untieStart(obj, index);
    return { score: restore(at, obj), tick, oldLength, newLength: 0 };
  }

  // A fórmula do compasso `index` (só dele) passa a `numerator`/`denominator`: em todas as pautas e vozes o compasso é
  // refeito, o que passar do fim novo sai e o que faltar vira pausa. Devolve { score, tick, oldLength, newLength } ou o
  // motivo ("signature", "grace", "figure").
  function setTimeSignature(at, score, index, numerator, denominator) {
    const master = score.masterBars[index];
    if (!master) return "missing";
    if (!(numerator >= 1 && numerator <= 32) || ![1, 2, 4, 8, 16, 32].includes(denominator)) return "signature";
    const tick = master.start;
    const oldLength = master.calculateDuration();
    const plans = [];
    for (const track of score.tracks) {
      for (const staff of track.staves) {
        const bar = staff.bars[index];
        for (let v = 0; v < bar.voices.length; v++) {
          if (hasGrace(at, staff, index, index, v)) return "grace";
          if (v > 0 && !bar.voices[v].beats.some((b) => b.notes.length)) continue;
          // Só o que começa no compasso (ou vem ligado de antes), cortado no fim antigo.
          const events = timeline(staff, v).filter((e) => e.start < tick + oldLength)
            .map((e) => ({ ...e, end: Math.min(e.end, tick + oldLength) }));
          plans.push({ bar, events, v });
        }
      }
    }
    master.timeSignatureNumerator = numerator;
    master.timeSignatureDenominator = denominator;
    for (const plan of plans) {
      if (!rebuildBar(at, plan.bar, plan.events, plan.v)) return "figure";
    }
    const obj = snapshot(at, score);
    untieStart(obj, index + 1);
    const fresh = restore(at, obj);
    return { score: fresh, tick, oldLength, newLength: fresh.masterBars[index].calculateDuration() };
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
          for (const note of beat.notes) list.push(note);
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

  // A batida de um endereço (o de uma nota, ou o do cursor de inserção, que aponta uma corda sem nota).
  function resolveBeat(score, path) {
    if (!path) return null;
    const [t, s, b, v, i] = path;
    const bar = score.tracks[t] && score.tracks[t].staves[s] && score.tracks[t].staves[s].bars[b];
    return (bar && bar.voices[v] && bar.voices[v].beats[i]) || null;
  }

  // O endereço de uma batida com uma corda (do alphaTab): o cursor de inserção.
  function caretOf(beat, alphaString) {
    const voice = beat.voice;
    const bar = voice.bar;
    return [bar.staff.track.index, bar.staff.index, bar.index, voice.index, beat.index, alphaString];
  }

  // Uma nota nova numa batida: numa corda vazia de um acorde, ou numa pausa, que vira nota. Devolve a nota, ou null
  // (corda ocupada, fora do braço, corda que a pista não tem).
  function insertNote(at, beat, alphaString, fret) {
    const staff = beat.voice.bar.staff;
    if (!staff.tuning || alphaString < 1 || alphaString > staff.tuning.length) return null;
    if (fret < 0 || fret > MAX_FRET || stringBusy(beat, alphaString, null)) return null;
    const note = new at.model.Note();
    note.string = alphaString;
    note.fret = fret;
    beat.isEmpty = false;
    beat.addNote(note);
    return note;
  }

  // Uma nota nova no tique `tick` (da grade), onde não começa batida nenhuma. No meio de uma nota longa, ela se divide:
  // o que soava continua, ligado (menos na corda da nota nova, que é atacada de novo), e a nota nova ataca em `tick`.
  // Numa pausa, a nota vai até a próxima (ou até o fim do compasso). Devolve true ou o motivo ("fret", "short",
  // "grace", "figure").
  function insertAt(at, staff, tick, alphaString, fret, v = 0) {
    const m = at.model;
    if (!staff.tuning || alphaString < 1 || alphaString > staff.tuning.length) return "fret";
    if (fret < 0 || fret > MAX_FRET) return "fret";
    tick = Math.round(tick);
    const bars = staff.bars;
    const events = timeline(staff, v);
    const index = events.findIndex((e) => e.start <= tick && tick < e.end);
    const note = new m.Note();
    note.string = alphaString;
    note.fret = fret;
    const beat = new m.Beat();
    let low = tick;
    let high;
    if (index >= 0) {
      const ev = events[index];
      if (tick - ev.start < MIN_TICKS || ev.end - tick < MIN_TICKS) return "short";
      // O que soa no tique continua ligado com o que a parte dele tem (o vibrato, o P.M., o resto do bend), como no
      // Dividir; as partes ligadas de depois ficam como estavam, com a nota nova no lugar da que soava na corda dela.
      curvesOf(ev);
      const pieces = [ev.beat, ...ev.tail];
      const piece = pieces.filter((b) => b.absolutePlaybackStart <= tick).pop();
      const cut = (tick - piece.absolutePlaybackStart) / piece.playbackDuration;
      for (const old of piece.notes) {
        if (old.string === alphaString) continue;
        const copy = tieCopy(at, old, piece !== ev.beat);
        copy.vibrato = old.vibrato;
        copy.isPalmMute = old.isPalmMute;
        copy.isLetRing = old.isLetRing;
        copy.harmonicType = old.harmonicType;
        copy.harmonicValue = old.harmonicValue;
        setBend(at, copy, held(bendPart(bendOf(old), cut, 1)), true);
        beat.addNote(copy);
      }
      const later = ev.tail.filter((b) => b.absolutePlaybackStart > tick);
      for (const b of later) {
        for (const old of b.notes.filter((n) => n.string === alphaString)) b.removeNote(old);
        b.addNote(tieCopy(at, note, false));
      }
      beat.tracklabLength = (later.length ? later[0].absolutePlaybackStart : ev.end) - tick;
      events.splice(index + 1, 0, { start: tick, end: ev.end, beat, tail: later, from: tick,
        breaks: later.map((b) => ({ tick: b.absolutePlaybackStart, beat: b })) });
      low = ev.start;
      high = ev.end;
      ev.end = tick;
    } else {
      const next = events.find((e) => e.start > tick);
      const bar = bars[barAt(staff, tick)];
      const barEnd = bar.masterBar.start + bar.masterBar.calculateDuration();
      high = Math.min(next ? next.start : Infinity, barEnd);
      if (high - tick < MIN_TICKS) return "short";
      events.push({ start: tick, end: high, beat, tail: [] });
      events.sort((a, b) => a.start - b.start);
    }
    beat.addNote(note);
    const first = barAt(staff, low);
    const last = barAt(staff, high - 1);
    if (hasGrace(at, staff, first, last, v)) return "grace";
    for (let b = first; b <= last; b++) {
      if (!rebuildBar(at, bars[b], events, v)) return "figure";
    }
    return true;
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
    tidyLinks(at, score);
    return at.model.JsonConverter.scoreToJsObject(score);
  }

  // As ligações entre notas (ligadura, ligado, slide, slur) de mão dupla e só entre notas da partitura. Um slide
  // desligado ou uma nota apagada deixava a outra ponta apontando para ela, e o alphaTab quebrava ao ler a cópia de
  // volta (procura a origem pelo id e não acha): a edição parava de desenhar e de gravar.
  function tidyLinks(at, score) {
    const notes = new Set();
    for (const track of score.tracks) {
      for (const staff of track.staves) {
        for (const bar of staff.bars) {
          for (const voice of bar.voices) {
            for (const beat of voice.beats) {
              for (const note of beat.notes) notes.add(note);
            }
          }
        }
      }
    }
    for (const note of notes) {
      const slide = note.slideOrigin;
      if (slide && (!notes.has(slide) || slide.slideTarget !== note)) note.slideOrigin = null;
      const hammer = note.hammerPullOrigin;
      if (hammer && (!notes.has(hammer) || !hammer.isHammerPullOrigin || hammer.hammerPullDestination !== note)) {
        note.hammerPullOrigin = null;
      }
      const slur = note.slurOrigin;
      if (slur && (!notes.has(slur) || slur.slurDestination !== note)) note.slurOrigin = null;
      if (note.tieOrigin && !notes.has(note.tieOrigin)) note.tieOrigin = null;
      if (note.slideTarget && !notes.has(note.slideTarget)) note.slideTarget = null;
      if (note.hammerPullDestination && (!notes.has(note.hammerPullDestination) || !note.isHammerPullOrigin)) {
        note.hammerPullDestination = null;
      }
      if (note.slurDestination && !notes.has(note.slurDestination)) note.slurDestination = null;
      if (note.tieDestination && !notes.has(note.tieDestination)) note.tieDestination = null;
    }
    // As ligaduras das cordas refeitas em ordem: cada ligada vem da nota anterior da corda na mesma voz (até três
    // compassos antes, como o alphaTab procura) e segue a casa dela. Um compasso refeito ou uma nota dividida deixavam a
    // ligada de depois presa à primeira, pulando as novas. Nas músicas do repertório, todas as ligaduras já eram assim.
    for (const track of score.tracks) {
      for (const staff of track.staves) {
        if (!staff.tuning || !staff.tuning.length) continue;
        const voices = Math.max(0, ...staff.bars.map((b) => b.voices.length));
        for (let v = 0; v < voices; v++) {
          const last = new Map();
          for (const bar of staff.bars) {
            for (const beat of bar.voices[v] ? bar.voices[v].beats : []) {
              for (const note of beat.notes) {
                note.tieDestination = null;
                const before = note.isTieDestination ? last.get(note.string) : null;
                const origin = before && bar.index - before.bar <= 3 ? before.note : null;
                note.tieOrigin = origin;
                if (origin) {
                  origin.tieDestination = note;
                  note.fret = origin.fret;
                } else {
                  note.isTieDestination = false;
                }
                last.set(note.string, { note, bar: bar.index });
              }
            }
          }
        }
      }
    }
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
    // O bend da própria nota (o editor da coluna), a altura que uma ligada traz da anterior, e o tempo dela mesma (os
    // pontos do bend vão de 0 a 60 ao longo da batida, não da cadeia ligada).
    const before = note.isTieDestination && note.tieOrigin ? bendOf(note.tieOrigin) : [];
    return { track: staff.track.index, string: tabString(note), fret: note.fret,
      bend: (note.bendPoints || []).map((p) => [p.offset, p.value]),
      carried: before.length ? before[before.length - 1][1] : 0,
      ownTick: note.beat.absolutePlaybackStart, ownLength: note.beat.playbackDuration,
      pitch: note.realValue, tick: sounding ? sounding.start : note.beat.absolutePlaybackStart,
      techniques: techniquesOf(at, note),
      voice: note.beat.voice.index + 1,
      figure: figureName(length), length, base: rhythm ? rhythm.base : null, dots: rhythm ? rhythm.dots : 0,
      triplet: rhythm ? rhythm.triplet : false, strings };
  }

  return {
    BENDS,
    GROUPS,
    MAX_FRET,
    MIN_TICKS,
    describe,
    exportGp,
    gpSafe,
    setBendPoints,
    findNote,
    fit,
    moveString,
    neighbor,
    notesOf,
    nudge,
    retime,
    split,
    tie,
    rangeOf,
    insertBar,
    deleteBar,
    setTimeSignature,
    copy,
    copied,
    paste,
    resolveBeat,
    caretOf,
    insertNote,
    insertAt,
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
