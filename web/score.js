// A partitura do estudo numa WKWebView: o Guitar Pro do pacote desenhado pelo alphaTab numa faixa horizontal,
// uma pista por vez. A página não toca nada: o app empurra o relógio (`tracklab.clock`) e o mapa de tempo
// (`tracklab.tempo`); a página leva segundos a tiques pelo mapa e tiques a x pelas batidas desenhadas.
//
// Cada compasso tem a largura da sua duração na escala da Fita (`span` segundos na largura), as notas ficam no seu
// tempo dentro dele (o alphaTab do projeto espaça pela duração) e as barras caem sobre as da Fita. O cursor fica
// parado nos 40 % e a pauta corre sob ele na velocidade da Fita.
//
// Do app para a página: load({gp, track, points}), track(n), tempo(points), clock(s, playing, rate, delay),
// span(segundos), loop(a, b) / loop(null), theme("light" | "dark"), zoom(escala).
// Da página para o app (webkit.messageHandlers.tracklab): ready, loaded {tracks, bars, barTicks}, rendered {bars, ms},
// seek {seconds}, error {message}.
(function () {
  "use strict";

  const core = window.trackCore;
  const viewport = document.getElementById("viewport");
  const sheet = document.getElementById("sheet");
  const tabElement = document.getElementById("tab");
  const cursor = document.getElementById("cursor");
  const loopBox = document.getElementById("loop");
  const message = document.getElementById("message");

  // Diferença entre o relógio extrapolado e um aviso do app abaixo da qual o aviso é ignorado.
  const CLOCK_TOLERANCE = 0.04;
  const FONT_TIMEOUT_MS = 8000;
  // Espera para desenhar de novo depois de mudar a escala, o mapa ou a largura da janela.
  const RELAYOUT_MS = 200;
  // Um compasso nunca fica mais estreito que isto (px), por mais curto que seja.
  const MIN_BAR_WIDTH = 24;

  const THEMES = {
    light: {
      mainGlyphColor: "#1d1d1f",
      secondaryGlyphColor: "#1d1d1f",
      staffLineColor: "#b4b4b9",
      barSeparatorColor: "#8e8e93",
      barNumberColor: "#8e8e93",
      scoreInfoColor: "#1d1d1f",
    },
    dark: {
      mainGlyphColor: "#ececf1",
      secondaryGlyphColor: "#ececf1",
      staffLineColor: "#5c5c61",
      barSeparatorColor: "#8e8e93",
      barNumberColor: "#98989d",
      scoreInfoColor: "#ececf1",
    },
  };

  const state = {
    api: null,
    score: null,
    track: 0,
    theme: "light",
    scale: 1,
    points: [],
    anchors: [],
    span: 10,
    // Medido no primeiro desenho de cada pista: quanto cada compasso tem antes das batidas (clave, fórmula).
    before: null,
    measuring: false,
    layoutWidth: 0,
    relayoutTimer: 0,
    clock: null,
    loop: null,
    renderStarted: 0,
    scroll: 0,
    cursorLeft: 0,
  };

  function post(body) {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tracklab;
    if (handler) {
      handler.postMessage(body);
    }
  }

  function report(error) {
    const text = error && error.message ? error.message : String(error);
    post({ type: "error", message: text });
  }

  function show(text) {
    message.textContent = text || "";
    message.hidden = !text;
  }

  function createSettings() {
    const settings = new alphaTab.Settings();
    settings.core.fontDirectory = "vendor/alphatab/";
    settings.core.engine = "svg";
    settings.core.useWorkers = false;
    settings.core.enableLazyLoading = false;
    settings.display.layoutMode = alphaTab.LayoutMode.Horizontal;
    settings.display.staveProfile = alphaTab.StaveProfile.Tab;
    settings.display.scale = state.scale;
    settings.player.enablePlayer = false;
    settings.player.playerMode = alphaTab.PlayerMode.Disabled;
    settings.notation.elements.set(alphaTab.NotationElement.TrackNames, false);
    settings.notation.elements.set(alphaTab.NotationElement.ScoreCopyright, false);
    settings.notation.rhythmMode = alphaTab.TabRhythmMode.ShowWithBars;
    const colors = THEMES[state.theme];
    for (const key of Object.keys(colors)) {
      if (key in settings.display.resources) {
        settings.display.resources[key] = alphaTab.model.Color.fromJson(colors[key]);
      }
    }
    return settings;
  }

  function createApi() {
    if (state.api) {
      state.api.destroy();
      tabElement.innerHTML = "";
    }
    const api = new alphaTab.AlphaTabApi(tabElement, createSettings());
    api.renderFinished.on(() => window.requestAnimationFrame(afterRender));
    api.error.on(report);
    state.api = api;
    return api;
  }

  function whenFontsLoaded(api, callback) {
    const facade = api.uiFacade;
    if (facade.canRender) {
      callback();
      return;
    }
    let done = false;
    facade.canRenderChanged.on(() => {
      if (!done && facade.canRender) {
        done = true;
        callback();
      }
    });
    window.setTimeout(() => {
      if (!done) {
        report(new Error("A fonte Bravura não carregou (vendor/alphatab/Bravura.woff2)."));
      }
    }, FONT_TIMEOUT_MS);
  }

  // A pauta começa a 40 % da largura, como a Fita começa a música sob a agulha.
  function lead() {
    return viewport.clientWidth * core.CURSOR_AT;
  }

  // Cada pista é desenhada duas vezes na primeira vez: a primeira mede quanto cada compasso tem antes das batidas
  // (clave, fórmula), a segunda desconta isso das larguras. Depois (escala, mapa, largura da janela), uma só.
  function render(second) {
    if (!state.score) {
      return;
    }
    const api = createApi();
    const track = Math.min(Math.max(0, state.track), state.score.tracks.length - 1);
    state.measuring = !state.before;
    sizeBars(track);
    sheet.style.visibility = state.measuring ? "hidden" : "";
    tabElement.style.marginLeft = lead() + "px";
    if (!second) {
      state.renderStarted = performance.now();
    }
    whenFontsLoaded(api, () => api.renderScore(state.score, [track]));
  }

  function relayout() {
    window.clearTimeout(state.relayoutTimer);
    state.relayoutTimer = window.setTimeout(() => render(), RELAYOUT_MS);
  }

  // A duração de um compasso pelo mapa; sem mapa, a 120 por minuto.
  function barSeconds(master) {
    const end = master.start + master.calculateDuration();
    if (state.points.length < 2) {
      return (end - master.start) / 1920;
    }
    return core.tickToSeconds(state.points, end) - core.tickToSeconds(state.points, master.start);
  }

  // Cada compasso da pista com a largura da sua duração na escala da Fita (o alphaTab do projeto espaça as notas
  // pelo tempo dentro dele).
  function sizeBars(track) {
    const masters = state.score.masterBars;
    const width = viewport.clientWidth || 1000;
    const before = state.before && state.before.length === masters.length ? state.before : null;
    const bars = masters.map((master, i) => ({ seconds: barSeconds(master), pre: before ? before[i] : 0 }));
    const widths = core.barWidths(bars, width / state.span, MIN_BAR_WIDTH);
    for (const staff of state.score.tracks[track].staves) {
      staff.bars.forEach((bar, i) => {
        bar.displayWidth = widths[i] / state.scale;
      });
    }
    state.layoutWidth = width;
  }

  // Quanto cada compasso tem antes das batidas: a clave e a fórmula; zero nos outros (a barra não ocupa largura).
  function measureBefore() {
    const before = new Array(state.score.masterBars.length).fill(0);
    for (const system of state.api.renderer.boundsLookup.staffSystems) {
      for (const masterBounds of system.bars) {
        const beat = masterBounds.bars[0] && masterBounds.bars[0].beats[0];
        if (beat) {
          before[masterBounds.index] = Math.max(0, beat.visualBounds.x - masterBounds.realBounds.x);
        }
      }
    }
    return before;
  }

  function decode(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  }

  // Pares [tique, x] em coordenadas de #sheet: o início de cada compasso na barra (depois da clave e da fórmula, quando
  // há) e o fim do último. Entre eles, uma reta: o tempo da Fita.
  function collectAnchors() {
    const lookup = state.api && state.api.renderer.boundsLookup;
    if (!lookup) {
      return [];
    }
    const surface = state.api.canvasElement.element.getBoundingClientRect();
    const page = sheet.getBoundingClientRect();
    const left = surface.left - page.left;
    const anchors = [];
    for (const system of lookup.staffSystems) {
      for (const masterBounds of system.bars) {
        const master = state.score.masterBars[masterBounds.index];
        if (!master) {
          continue;
        }
        const x = masterBounds.realBounds.x + left;
        const first = masterBounds.bars[0] && masterBounds.bars[0].beats[0];
        anchors.push([master.start, first ? Math.max(x, first.visualBounds.x + left) : x]);
        // O fim de um compasso cai no tique do início do seguinte, que fica (o maior x): só o do último sobra.
        anchors.push([master.start + master.calculateDuration(), x + masterBounds.realBounds.w]);
      }
    }
    return core.cleanAnchors(anchors);
  }

  function afterRender() {
    if (state.measuring) {
      state.before = measureBefore();
      render(true);
      return;
    }
    state.anchors = collectAnchors();
    const width = Math.ceil(lead() + tabElement.scrollWidth + viewport.clientWidth * (1 - core.CURSOR_AT));
    sheet.style.width = width + "px";
    sheet.style.visibility = "";
    drawLoop();
    draw(true);
    post({
      type: "rendered",
      bars: state.score ? state.score.masterBars.length : 0,
      height: Math.ceil(tabElement.scrollHeight),
      ms: Math.round(performance.now() - state.renderStarted),
    });
  }

  function xAtSeconds(seconds) {
    if (!state.points.length || !state.anchors.length) {
      return null;
    }
    return core.followX(state.anchors, core.secondsToTick(state.points, seconds));
  }

  // O cursor fica nos 40 % e a pauta corre sob ele, na velocidade da Fita. A pauta anda por `transform` (frações de
  // pixel, na GPU; `scrollLeft` arredonda e alterna passos de 1 e 2 px) e o cursor fica fora dela, parado na tela.
  // `now`: a hora do quadro (requestAnimationFrame), para os passos saírem iguais.
  function draw(force, now = performance.now()) {
    const x = xAtSeconds(core.estimate(state.clock, now));
    if (x === null) {
      cursor.hidden = true;
      return;
    }
    const playing = state.clock && state.clock.playing;
    const width = viewport.clientWidth;
    const outside = x < state.scroll || x > state.scroll + width;
    if (playing || force || outside) {
      const target = core.scrollFor(x, width);
      if (force || Math.abs(target - state.scroll) >= 0.01) {
        sheet.style.transform = `translate3d(${-target}px, 0, 0)`;
        state.scroll = target;
      }
    }
    const left = x - state.scroll;
    if (force || cursor.hidden || Math.abs(left - state.cursorLeft) >= 0.01) {
      cursor.style.transform = `translate3d(${left}px, 0, 0)`;
      state.cursorLeft = left;
    }
    cursor.hidden = false;
  }

  function drawLoop() {
    if (!state.loop) {
      loopBox.hidden = true;
      return;
    }
    const a = xAtSeconds(state.loop[0]);
    const b = xAtSeconds(state.loop[1]);
    if (a === null || b === null || b <= a) {
      loopBox.hidden = true;
      return;
    }
    loopBox.hidden = false;
    loopBox.style.left = a + "px";
    loopBox.style.width = b - a + "px";
  }

  function frame(now) {
    if (state.clock && state.clock.playing) {
      draw(false, now);
    }
    window.requestAnimationFrame(frame);
  }

  sheet.addEventListener("click", (event) => {
    if (!state.anchors.length || !state.points.length) {
      return;
    }
    const page = sheet.getBoundingClientRect();
    const tick = core.tickAtX(state.anchors, event.clientX - page.left);
    post({ type: "seek", seconds: Math.max(0, core.tickToSeconds(state.points, tick)) });
  });

  window.addEventListener("resize", () => {
    draw(true);
    if (Math.abs(viewport.clientWidth - state.layoutWidth) > 1) {
      relayout();
    }
  });

  window.tracklab = {
    load(payload) {
      try {
        state.score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(decode(payload.gp), new alphaTab.Settings());
      } catch (error) {
        state.score = null;
        show("Não consegui ler a partitura desta música.");
        report(error);
        return;
      }
      show("");
      state.before = null;
      state.track = Number.isInteger(payload.track) ? payload.track : 0;
      state.points = core.cleanPoints(payload.points);
      const masters = state.score.masterBars;
      const last = masters[masters.length - 1];
      post({
        type: "loaded",
        bars: masters.length,
        // Início de cada compasso em tiques, mais o fim do último: a Fita desenha os compassos por eles.
        barTicks: masters.map((m) => m.start).concat(last ? [last.start + last.calculateDuration()] : []),
        tracks: state.score.tracks.map((track, index) => ({ index, name: track.name || "Faixa " + (index + 1) })),
      });
      render();
    },
    track(index) {
      if (!state.score || index === state.track) {
        return;
      }
      state.track = index;
      state.before = null;
      render();
    },
    tempo(points) {
      state.points = core.cleanPoints(points);
      drawLoop();
      draw(true);
      relayout();
    },
    clock(seconds, playing, rate, delay) {
      state.clock = core.nextClock(state.clock, { seconds, playing, rate, delay }, performance.now(), CLOCK_TOLERANCE);
      draw(!playing);
    },
    span(seconds) {
      if (!Number.isFinite(seconds) || seconds <= 0 || seconds === state.span) {
        return;
      }
      state.span = seconds;
      relayout();
    },
    loop(start, end) {
      state.loop = Number.isFinite(start) && Number.isFinite(end) && end > start ? [start, end] : null;
      drawLoop();
    },
    theme(name) {
      if (!THEMES[name] || name === state.theme) {
        return;
      }
      state.theme = name;
      document.documentElement.dataset.theme = name;
      render();
    },
    zoom(scale) {
      if (!Number.isFinite(scale) || scale === state.scale) {
        return;
      }
      state.scale = Math.min(Math.max(scale, 0.5), 2);
      state.before = null;
      render();
    },
  };

  window.addEventListener("error", (event) => report(event.error || event.message));
  window.requestAnimationFrame(frame);
  show("Carregando a partitura…");
  post({ type: "ready" });
})();
