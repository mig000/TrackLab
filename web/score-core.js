// Contas da página da partitura sem DOM nem alphaTab, para o node testar (check-score.cjs).
// Tiques são os do mapa de tempo do motor: 960 por semínima, os mesmos do alphaTab.
(function (root, factory) {
  const core = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = core;
  } else {
    root.trackCore = core;
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  // Onde o cursor fica na largura da janela enquanto toca: o que vem pela frente aparece mais.
  const CURSOR_AT = 0.4;
  // Um loop que ocupa até esta fração da largura cabe na tela: a pauta para e só o cursor anda.

  // Último índice com valor <= x numa lista ordenada por `key`; -1 antes do primeiro.
  function floorIndex(list, x, key) {
    let low = 0;
    let high = list.length - 1;
    let found = -1;
    while (low <= high) {
      const mid = (low + high) >> 1;
      if (key(list[mid]) <= x) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }

  // Interpolação por trechos de uma lista de pares ordenada por `ka`; fora dela, segue a reta do trecho da ponta.
  function piecewise(list, x, ka, kb) {
    if (!list.length) {
      return NaN;
    }
    if (list.length === 1) {
      return kb(list[0]);
    }
    let i = floorIndex(list, x, ka);
    i = Math.min(Math.max(i, 0), list.length - 2);
    const a = list[i];
    const b = list[i + 1];
    const span = ka(b) - ka(a);
    if (span <= 0) {
      return kb(a);
    }
    return kb(a) + ((x - ka(a)) / span) * (kb(b) - kb(a));
  }

  // Pontos do mapa válidos, em ordem e estritamente crescentes nos dois eixos.
  function cleanPoints(points) {
    const sorted = (points || [])
      .filter((p) => p && Number.isFinite(p.tick) && Number.isFinite(p.seconds))
      .sort((a, b) => a.tick - b.tick);
    const out = [];
    for (const p of sorted) {
      const last = out[out.length - 1];
      if (!last || (p.tick > last.tick && p.seconds > last.seconds)) {
        out.push({ tick: p.tick, seconds: p.seconds, kind: p.kind });
      }
    }
    return out;
  }

  // No modo página: o índice da última batida (em ordem de tique) que já começou em `tick`; -1 antes da primeira.
  function beatIndexAt(ticks, tick) {
    let low = 0;
    let high = ticks.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (ticks[middle] <= tick + 1e-6) low = middle + 1;
      else high = middle;
    }
    return low - 1;
  }

  function secondsToTick(points, seconds) {
    return piecewise(points, seconds, (p) => p.seconds, (p) => p.tick);
  }

  function tickToSeconds(points, tick) {
    return piecewise(points, tick, (p) => p.tick, (p) => p.seconds);
  }

  // O mapa de tempo depois de um trecho de `oldLength` tiques em `tick` virar `newLength` (um compasso posto, apagado ou
  // com outra fórmula). O que vem depois anda nos tiques e fica nos mesmos segundos (continua no lugar do áudio); os
  // pontos de dentro de um compasso que mudou de fórmula se esticam no tempo dele. Um compasso posto reparte com o de
  // antes o tempo que era dele, e um apagado deixa o tempo dele para o de antes: o de antes (desde o último ponto que não
  // é interpolado) encolhe ou estica por igual, com as batidas dele na mesma proporção.
  function reshapePoints(points, tick, oldLength, newLength) {
    const end = tick + oldLength;
    const delta = newLength - oldLength;
    const before = points.filter((p) => p.tick < tick - 0.5);
    const base = before.slice().reverse().find((p) => p.kind !== "interpolated") || before[0] || null;
    // O tempo do compasso de antes: até `tick` hoje; depois, até onde o seguinte começa (posto: o novo cabe nele).
    const was = tickToSeconds(points, tick);
    const will = newLength === 0 ? tickToSeconds(points, end) : was;
    const share = base && oldLength === 0 ? (tick - base.tick) / (tick + newLength - base.tick) : 1;
    const stretch = base && newLength === 0 && was > base.seconds ? (will - base.seconds) / (was - base.seconds) : 1;
    const scale = (p) => (base && p.tick > base.tick + 0.5 && p.tick < tick - 0.5
      ? { ...p, seconds: base.seconds + (p.seconds - base.seconds) * share * stretch } : p);
    const out = [];
    for (const p of points) {
      if (p.tick < tick - 0.5) {
        out.push(scale(p));
      } else if (p.tick >= end - 0.5 && (oldLength > 0 || p.tick >= tick - 0.5)) {
        out.push({ ...p, tick: p.tick + delta });
      } else if (oldLength > 0 && newLength > 0) {
        out.push({ ...p, tick: tick + (p.tick - tick) * (newLength / oldLength) });
      }
      // Apagado: os pontos de dentro (e o do começo, que o seguinte ocupa) saem.
    }
    if (oldLength === 0 && newLength > 0) {
      // O começo do compasso posto: o compasso de antes e ele repartem o tempo, pelos tiques.
      const seconds = base ? base.seconds + (was - base.seconds) * share : was - newLength * slopeAt(points);
      out.push({ tick, seconds, kind: "interpolated" });
    }
    if (newLength === 0 && !out.some((p) => Math.abs(p.tick - tick) < 0.5)) {
      // O último compasso apagado: o fim dele vira o fim da música.
      out.push({ tick, seconds: tickToSeconds(points, end), kind: "interpolated" });
    }
    return cleanPoints(out.sort((a, b) => a.tick - b.tick));
  }

  // Segundos por tique no começo do mapa (para um compasso posto antes de tudo).
  function slopeAt(points) {
    if (points.length < 2) return 0.5 / 960;
    return (points[1].seconds - points[0].seconds) / Math.max(1, points[1].tick - points[0].tick);
  }

  // Âncoras [tique, x] da pauta desenhada, em ordem de tique; x nunca volta. Num tique repetido (o fim de um
  // compasso e o início do seguinte) fica o maior x: depois da clave e da fórmula, quando o seguinte as tem.
  function cleanAnchors(anchors) {
    const sorted = anchors
      .filter((a) => Number.isFinite(a[0]) && Number.isFinite(a[1]))
      .sort((a, b) => a[0] - b[0] || b[1] - a[1]);
    const out = [];
    for (const a of sorted) {
      const last = out[out.length - 1];
      if (!last) {
        out.push(a);
      } else if (a[0] > last[0] && a[1] >= last[1]) {
        out.push(a);
      }
    }
    return out;
  }

  // O tique de um x (o clique na pauta), o inverso de followX dentro das âncoras.
  function tickAtX(anchors, x) {
    if (!anchors.length) {
      return 0;
    }
    if (x <= anchors[0][1]) {
      return anchors[0][0];
    }
    const last = anchors[anchors.length - 1];
    if (x >= last[1]) {
      return last[0];
    }
    const byX = anchors.filter((a, i) => i === 0 || a[1] > anchors[i - 1][1]);
    return piecewise(byX, x, (a) => a[1], (a) => a[0]);
  }

  // O x de um tique na reta das âncoras, também antes da primeira e depois da última: a pauta anda desde o começo do
  // áudio, antes do primeiro compasso, como a Fita.
  function followX(anchors, tick) {
    return anchors.length ? piecewise(anchors, tick, (a) => a[0], (a) => a[1]) : 0;
  }

  // O x de um segundo: segundo → tique pelo mapa, tique → x pelas âncoras. Antes do primeiro ponto do mapa e depois
  // do último, em linha reta na escala da Fita (`pxPerSecond`): a primeira batida pode ser irregular (um toque do
  // Bater junto) e não deve ditar a escala da introdução.
  function xAtSeconds(points, anchors, seconds, pxPerSecond) {
    const first = points[0];
    const last = points[points.length - 1];
    if (seconds < first.seconds) {
      return followX(anchors, first.tick) - (first.seconds - seconds) * pxPerSecond;
    }
    if (seconds > last.seconds) {
      return followX(anchors, last.tick) + (seconds - last.seconds) * pxPerSecond;
    }
    return followX(anchors, secondsToTick(points, seconds));
  }

  // Largura de cada compasso para que de um início de compasso ao seguinte a pauta ande `pxPerSecond` por segundo,
  // como a Fita: a duração vezes a escala, mais o que vem antes das batidas deste compasso (clave, fórmula), menos o
  // que vem antes das do seguinte. `bars`: [{seconds, pre}].
  function barWidths(bars, pxPerSecond, minWidth) {
    return bars.map((bar, i) => {
      const next = i + 1 < bars.length ? bars[i + 1].pre : 0;
      return Math.max(minWidth, bar.seconds * pxPerSecond + bar.pre - next);
    });
  }

  // O tempo da música agora a partir do último aviso do app: parado, o próprio aviso; tocando, extrapolado na
  // velocidade depois de `delay` segundos (o som do play ainda não saiu: a latência da saída). Com `loop` ([a, b] em
  // segundos), dá a volta como o motor de áudio (o PlaybackPlan do app): tocando de antes do fim do loop, ao chegar ao
  // fim volta ao começo; de depois do fim, segue solto. Sem isso a pauta passava do fim do loop até o próximo aviso.
  function estimate(clock, now, loop) {
    if (!clock) {
      return 0;
    }
    if (!clock.playing) {
      return clock.seconds;
    }
    const raw = clock.seconds + Math.max(0, (now - clock.at) / 1000 - (clock.delay || 0)) * clock.rate;
    return wrap(raw, clock.seconds, loop);
  }

  function wrap(seconds, from, loop) {
    if (!loop || from >= loop[1] || seconds < loop[1]) {
      return seconds;
    }
    const length = loop[1] - loop[0];
    return length > 0 ? loop[0] + ((seconds - loop[1]) % length) : seconds;
  }

  // Um aviso novo do app: aceito quando parado, ou quando a extrapolação já se afastou mais que `tolerance`
  // (pequenas diferenças fariam o cursor tremer).
  function nextClock(previous, update, now, tolerance, loop) {
    const fresh = { seconds: update.seconds, playing: update.playing, rate: update.rate, delay: update.delay || 0, at: now };
    if (!previous || !previous.playing || !update.playing || previous.rate !== update.rate) {
      return fresh;
    }
    return Math.abs(estimate(previous, now, loop) - update.seconds) > tolerance ? fresh : previous;
  }

  // Com um loop que cabe na tela e o cursor dentro dele, a janela fica parada e só o cursor anda: o segundo do começo
  // da janela, ou null (a janela segue o cursor a 40 %). Um loop até 60 % da largura começa nos 40 %, onde o cursor
  // estava ao entrar nele (nada salta); maior, fica centrado. A Fita usa a mesma conta (LoopView no app).
  function windowStart(seconds, loop, pin) {
    if (pin === null || pin === undefined || !loop || seconds < loop[0] - 1e-3 || seconds > loop[1] + 1e-3) {
      return null;
    }
    return pin;
  }

  // Quanto a pauta rola para o ponto `x` ficar sob o cursor, que fica a `at` da largura (0,4 até um clique pôr o
  // cabeçote noutro lugar). Sem piso em zero: antes da música a pauta desce para a direita junto com a Fita.
  function scrollFor(x, width, at = CURSOR_AT) {
    return x - width * at;
  }

  // O que cada pauta mostra (com o perfil Default do alphaTab): TAB nas de cordas; partitura na bateria e no que não
  // tem cordas. Muda o modelo lido do Guitar Pro, sem desenhar.
  function showPreferences(score) {
    for (const track of score.tracks) {
      for (const staff of track.staves) {
        const tab = !staff.isPercussion && Boolean(staff.tuning) && staff.tuning.length > 0;
        staff.showTablature = tab;
        staff.showStandardNotation = !tab;
      }
    }
  }

  // As notas de cada pista do Guitar Pro lido, para as barras sobre o espectro da Fita: [tique, duração em tiques, altura
  // MIDI, corda (1 é a mais aguda), casa, vibrato (0, 1 leve, 2 largo), a altura MIDI do trinado (0 sem trinado), e os
  // pontos do bend em pares (deslocamento de 0 a 60 ao longo da nota, valor em quartos de tom)…]. Uma nota ligada (tie) soma a duração das seguintes e elas não
  // entram; a bateria não tem altura e fica de fora (lista vazia).
  function trackNotes(score) {
    return score.tracks.map((track) => {
      const notes = [];
      if (track.staves.some((staff) => staff.isPercussion)) {
        return notes;
      }
      for (const staff of track.staves) {
        for (const bar of staff.bars) {
          for (const voice of bar.voices) {
            for (const beat of voice.beats) {
              for (const note of beat.notes) {
                if (note.isTieDestination) {
                  continue;
                }
                let duration = beat.playbackDuration;
                for (let tied = note.tieDestination; tied; tied = tied.tieDestination) {
                  duration += tied.beat.playbackDuration;
                }
                const strings = staff.tuning ? staff.tuning.length : 0;
                const vibrato = note.vibrato === 2 ? 2 : note.vibrato ? 1 : 0;
                const bend = (note.bendPoints || []).flatMap((p) => [p.offset, p.value]);
                const trill = note.isTrill ? note.realValue + note.trillFret - note.fret : 0;
                notes.push([beat.absolutePlaybackStart, duration, note.realValue, strings ? strings - note.string + 1 : 0,
                  note.fret, vibrato, trill, ...bend]);
              }
            }
          }
        }
      }
      return notes;
    });
  }

  return {
    CURSOR_AT,
    trackNotes,
    showPreferences,
    cleanPoints,
    secondsToTick,
    beatIndexAt,
    tickToSeconds,
    reshapePoints,
    cleanAnchors,
    tickAtX,
    followX,
    xAtSeconds,
    barWidths,
    estimate,
    nextClock,
    windowStart,
    scrollFor,
  };
});
