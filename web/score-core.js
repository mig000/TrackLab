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

  function secondsToTick(points, seconds) {
    return piecewise(points, seconds, (p) => p.seconds, (p) => p.tick);
  }

  function tickToSeconds(points, tick) {
    return piecewise(points, tick, (p) => p.tick, (p) => p.seconds);
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
  // velocidade depois de `delay` segundos (o som do play ainda não saiu: a latência da saída).
  function estimate(clock, now) {
    if (!clock) {
      return 0;
    }
    if (!clock.playing) {
      return clock.seconds;
    }
    return clock.seconds + Math.max(0, (now - clock.at) / 1000 - (clock.delay || 0)) * clock.rate;
  }

  // Um aviso novo do app: aceito quando parado, ou quando a extrapolação já se afastou mais que `tolerance`
  // (pequenas diferenças fariam o cursor tremer).
  function nextClock(previous, update, now, tolerance) {
    const fresh = { seconds: update.seconds, playing: update.playing, rate: update.rate, delay: update.delay || 0, at: now };
    if (!previous || !previous.playing || !update.playing || previous.rate !== update.rate) {
      return fresh;
    }
    return Math.abs(estimate(previous, now) - update.seconds) > tolerance ? fresh : previous;
  }

  function scrollFor(x, width) {
    return Math.max(0, x - width * CURSOR_AT);
  }

  return {
    CURSOR_AT,
    cleanPoints,
    secondsToTick,
    tickToSeconds,
    cleanAnchors,
    tickAtX,
    followX,
    barWidths,
    estimate,
    nextClock,
    scrollFor,
  };
});
