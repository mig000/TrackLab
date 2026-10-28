// A partitura do estudo numa WKWebView: o Guitar Pro do pacote desenhado pelo alphaTab numa faixa horizontal,
// uma pista por vez. A página não toca nada: o app empurra o relógio (`tracklab.clock`) e o mapa de tempo
// (`tracklab.tempo`); a página leva segundos a tiques pelo mapa e tiques a x pelas batidas desenhadas.
//
// Do app para a página: load({gp, track, points}), track(n), tempo(points), clock(s, playing, rate),
// loop(a, b) / loop(null), theme("light" | "dark"), zoom(escala).
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
    clock: null,
    loop: null,
    renderStarted: 0,
    lastScroll: -1,
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

  function render() {
    if (!state.score) {
      return;
    }
    const api = createApi();
    const track = Math.min(Math.max(0, state.track), state.score.tracks.length - 1);
    state.renderStarted = performance.now();
    whenFontsLoaded(api, () => api.renderScore(state.score, [track]));
  }

  function decode(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  }

  // Pares [tique, x] das batidas desenhadas e do fim de cada compasso, em coordenadas de #sheet.
  function collectAnchors() {
    const lookup = state.api && state.api.renderer.boundsLookup;
    if (!lookup) {
      return [];
    }
    const surface = state.api.canvasElement.element.getBoundingClientRect();
    const page = sheet.getBoundingClientRect();
    const left = surface.left - page.left;
    const points = [];
    for (const system of lookup.staffSystems) {
      for (const masterBounds of system.bars) {
        const master = state.score.masterBars[masterBounds.index];
        if (master) {
          const end = master.start + master.calculateDuration();
          points.push([end, masterBounds.realBounds.x + masterBounds.realBounds.w + left]);
        }
        for (const bar of masterBounds.bars) {
          for (const beat of bar.beats) {
            points.push([beat.beat.absolutePlaybackStart, beat.onNotesX + left]);
          }
        }
      }
    }
    return core.cleanAnchors(points);
  }

  function afterRender() {
    state.anchors = collectAnchors();
    const width = Math.ceil(tabElement.scrollWidth);
    sheet.style.width = width + "px";
    state.lastScroll = -1;
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
    return core.xAtTick(state.anchors, core.secondsToTick(state.points, seconds));
  }

  function draw(force) {
    const x = xAtSeconds(core.estimate(state.clock, performance.now()));
    if (x === null) {
      cursor.hidden = true;
      return;
    }
    cursor.hidden = false;
    cursor.style.left = x + "px";
    const playing = state.clock && state.clock.playing;
    const width = viewport.clientWidth;
    const outside = x < viewport.scrollLeft || x > viewport.scrollLeft + width;
    if (playing || force || outside) {
      const target = core.scrollFor(x, width);
      if (Math.abs(target - state.lastScroll) >= 0.5) {
        viewport.scrollLeft = target;
        state.lastScroll = target;
      }
    }
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

  function frame() {
    if (state.clock && state.clock.playing) {
      draw(false);
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
    state.lastScroll = -1;
    draw(true);
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
      render();
    },
    tempo(points) {
      state.points = core.cleanPoints(points);
      drawLoop();
      draw(true);
    },
    clock(seconds, playing, rate) {
      state.clock = core.nextClock(state.clock, { seconds, playing, rate }, performance.now(), CLOCK_TOLERANCE);
      draw(!playing);
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
      render();
    },
  };

  window.addEventListener("error", (event) => report(event.error || event.message));
  window.requestAnimationFrame(frame);
  show("Carregando a partitura…");
  post({ type: "ready" });
})();
