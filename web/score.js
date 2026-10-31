// A partitura do estudo numa WKWebView: o Guitar Pro do pacote desenhado pelo alphaTab numa faixa horizontal,
// uma pista (e, se pedida, uma segunda embaixo, nos mesmos compassos). As pistas de cordas aparecem em TAB; a bateria
// (que não tem TAB) em partitura. A página não toca nada: o app empurra o relógio (`tracklab.clock`) e o mapa de tempo
// (`tracklab.tempo`); a página leva segundos a tiques pelo mapa e tiques a x pelas batidas desenhadas.
//
// Cada compasso tem a largura da sua duração na escala da Fita (`span` segundos na largura), as notas ficam no seu
// tempo dentro dele (o alphaTab do projeto espaça pela duração) e as barras caem sobre as da Fita. O cursor fica
// parado nos 40 % e a pauta corre sob ele na velocidade da Fita.
//
// No Ajuste, ⇧ + arrastar desliza a onda da Fita sob as linhas paradas (a pauta e o cursor não se mexem); ao soltar,
// o app leva a batida do cursor até o som que ficou sob a linha.
//
// Edição (como a do TabLab, sobre o próprio Guitar Pro, score-edit.js): com `editing(true)`, um clique escolhe a nota
// (sem levar a música até ela) e o app manda `edit(op, valor)`: technique, fret, string, transpose, fit, select, delete, nav, undo,
// redo, clear. A página responde `selection {…}` (ou null) e, 1,5 s depois da última mudança, `save {gp}` (o Guitar
// Pro 7 em base64) e `notes` (as notas novas, para o espectro).
//
// Do app para a página: load({gp, track, points, others, page}), track(n), others([n…]), page(sim), tempo(points),
// clock(s, playing, rate, delay),
// span(segundos), adjusting(sim), loop(a, b) / loop(null), view(fração do cursor, pino do loop ou null),
// theme("light" | "dark"), zoom(escala).
// Da página para o app (webkit.messageHandlers.tracklab): ready, loaded {tracks, bars, barTicks, sections},
// rendered {bars, ms},
// seek {seconds}, shift {seconds} (quanto a onda andou no arrasto com ⇧), shiftEnd {seconds} (o total, ao soltar),
// error {message}.
(function () {
  "use strict";

  const core = window.trackCore;
  const edit = window.trackEdit;
  const selectionBox = document.getElementById("selection");
  // Os contornos das outras notas escolhidas (com ⇧ ou ⌘), embaixo do da principal.
  const groupLayer = document.createElement("div");
  groupLayer.id = "group-selection";
  // O cursor de inserção (uma corda vazia da batida, ou uma pausa): digitar a casa põe a nota ali.
  const caretBox = document.createElement("div");
  caretBox.id = "caret";
  caretBox.hidden = true;
  const SAVE_MS = 1500;
  const UNDO_LIMIT = 50;
  const viewport = document.getElementById("viewport");
  const sheet = document.getElementById("sheet");
  // A camada desenhada que está na tela; um desenho novo vai para outra camada, escondida, e só troca quando termina
  // (sem a pauta sumir no meio de um zoom ou de uma mudança de mapa).
  let tabElement = document.getElementById("tab");
  const cursor = document.getElementById("cursor");
  const loopBox = document.getElementById("loop");
  const pageCursor = document.getElementById("page-cursor");
  const noteGhost = document.getElementById("note-ghost");
  const pageLoop = document.getElementById("page-loop");
  const message = document.getElementById("message");

  // Diferença entre o relógio extrapolado e um aviso do app abaixo da qual o aviso é ignorado.
  const CLOCK_TOLERANCE = 0.04;
  const FONT_TIMEOUT_MS = 8000;
  // Espera para desenhar de novo depois de mudar a escala, o mapa ou a largura da janela.
  const RELAYOUT_MS = 200;
  // Um compasso nunca fica mais estreito que isto (px), por mais curto que seja.
  const MIN_BAR_WIDTH = 24;
  // Por que uma nota não mudou de tempo (edit.retime).
  const RETIME_REASONS = {
    overlap: "Passaria por cima da nota anterior.",
    short: "A nota (ou a de antes) ficaria curta demais.",
    grace: "Um compasso com apojatura não é refeito assim.",
    figure: "A duração não cabe em figuras (nem com tercinas): use outra grade.",
    missing: "Não achei a nota na voz 1.",
    next: "Não cabe: a nota seguinte começa antes. Apague ou encurte a seguinte primeiro.",
    end: "Não cabe: o trecho passaria do fim da música.",
    same: "A nota já está dividida aí.",
  };

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
    // A segunda pista, desenhada embaixo da primeira (null: nenhuma).
    others: [],
    // Onde o cursor fica na largura (0,4; um clique na pauta, na Onda ou na Lente põe o cabeçote sob o mouse).
    cursorAt: core.CURSOR_AT,
    // Onde a pauta para enquanto a música está no loop (o app escolhe, como na Fita), ou null.
    pin: null,
    // A pauta parada nesse começo (segundos) enquanto uma nota clicada toca, ou null.
    hold: null,
    // O loop sendo marcado na faixa (de onde saiu, em pixels da tela).
    loopDrag: null,
    // As barras de duração na edição e a grade delas (tiques: 240 é semicolcheia, 320 tercina de colcheia…).
    durations: false,
    grid: 240,
    durDrag: null,
    // A nota pega na TAB para mudar de tempo (path, intervalo, de onde saiu, para onde vai).
    noteDrag: null,
    // O loop sendo marcado no modo página (a batida de onde saiu e a de agora).
    pageDrag: null,
    // O modo página: a partitura em sistemas, de cima para baixo; as batidas da pista principal (tique e a batida do
    // alphaTab) para o cursor.
    page: false,
    pageBeats: [],
    pageTicks: [],
    pageSystem: null,
    theme: "light",
    scale: 1,
    points: [],
    anchors: [],
    span: 10,
    // A escala (segundos na largura) do desenho que está na tela: com o zoom mudando, a camada é esticada na hora
    // (renderedSpan / span) até o desenho novo chegar, e a TAB acompanha a Fita sem esperar o alphaTab.
    renderedSpan: 10,
    // O desenho em curso, numa camada escondida: {api, element}.
    next: null,
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
    adjusting: false,
    // O arrasto com ⇧ em curso: de onde saiu e quanto o mouse andou (px).
    shiftDrag: null,
    // O clique que segue o fim de um arrasto não é um clique.
    suppressClick: false,
    // A edição da TAB: ligada, a nota escolhida (o endereço, que sobrevive à cópia), os passos do Desfazer e do
    // Refazer (cópias da partitura) e a gravação pendente.
    editing: false,
    selected: null,
    // Várias notas escolhidas (⇧ clique, ⌘ clique, ⇧← →): os endereços de todas, com a principal, ou null para uma só;
    // `anchor` é de onde um ⇧ estende.
    group: null,
    anchor: null,
    // O cursor de inserção: uma corda sem nota numa batida (o endereço da batida e a corda do alphaTab), ou null.
    caret: null,
    // A voz em que a nota nova entra (0: voz 1; 1: voz 2).
    caretVoice: 0,
    // A casa sugerida para a nota nova (um som sem nota escrita, achado pelo app), ou null.
    suggestedFret: null,
    undo: [],
    redo: [],
    saveTimer: 0,
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
    // As caixas de cada nota, para escolher a nota com o clique na edição.
    settings.core.includeNoteBounds = true;
    settings.display.layoutMode = state.page ? alphaTab.LayoutMode.Page : alphaTab.LayoutMode.Horizontal;
    // Cada pauta diz o que mostra (showPreferences): TAB nas de cordas, partitura na bateria. Com o perfil "só TAB"
    // a bateria, que não tem TAB, quebrava o desenho.
    settings.display.staveProfile = alphaTab.StaveProfile.Default;
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

  // Uma camada nova, escondida, para o próximo desenho; um desenho anterior que ainda não terminou é descartado.
  function createApi() {
    if (state.next) {
      state.next.api.destroy();
      state.next.element.remove();
    }
    const element = document.createElement("div");
    element.className = "layer pending";
    sheet.appendChild(element);
    const api = new alphaTab.AlphaTabApi(element, createSettings());
    const next = { api, element, span: state.span };
    api.renderFinished.on(() => window.requestAnimationFrame(() => afterRender(next)));
    api.error.on(report);
    state.next = next;
    return next;
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
      // Só o desenho em curso conta: um descartado (veio outro depois, como a segunda passada ou um zoom) não avisa.
      const current = (state.next && state.next.api === api) || state.api === api;
      if (!done && current && !facade.canRender) {
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
  function render(again) {
    if (!state.score) {
      return;
    }
    const next = createApi();
    const tracks = shownTracks();
    if (state.page) {
      // Em páginas o alphaTab quebra os sistemas na largura da janela: sem as larguras da escala da Fita.
      state.measuring = false;
      next.element.style.marginLeft = "0px";
      if (!again) {
        state.renderStarted = performance.now();
      }
      whenFontsLoaded(next.api, () => next.api.renderScore(state.score, tracks));
      return;
    }
    state.measuring = !state.before;
    tracks.forEach(sizeBars);
    next.element.style.marginLeft = lead() + "px";
    if (!again) {
      state.renderStarted = performance.now();
    }
    whenFontsLoaded(next.api, () => next.api.renderScore(state.score, tracks));
  }

  // A pista principal e as outras escolhidas, embaixo dela nos mesmos compassos (sem repetir nem passar do fim).
  function shownTracks() {
    const last = state.score.tracks.length - 1;
    const track = Math.min(Math.max(0, state.track), last);
    const list = [track];
    for (const other of state.others) {
      if (Number.isInteger(other) && other >= 0 && other <= last && !list.includes(other)) list.push(other);
    }
    return list;
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
    // Com mais de uma pauta (a segunda pista), o layout horizontal do alphaTab usa a largura do masterBar, não a de
    // cada pauta: sem ela os compassos saíam quase o dobro e a TAB descolava da Fita longe do cursor.
    masters.forEach((master, i) => {
      master.displayWidth = widths[i] / state.scale;
    });
    state.layoutWidth = width;
  }

  // Quanto cada compasso tem antes das batidas: a clave e a fórmula; zero nos outros (a barra não ocupa largura).
  // Medido na pista principal, a mesma das âncoras: na segunda, uma pausa de compasso inteiro fica no meio dele e não
  // marca tempo nenhum.
  function measureBefore(api) {
    const before = new Array(state.score.masterBars.length).fill(0);
    for (const system of api.renderer.boundsLookup.staffSystems) {
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
  function collectAnchors(api) {
    const lookup = api && api.renderer.boundsLookup;
    if (!lookup) {
      return [];
    }
    // Em coordenadas de #sheet sem o esticamento do zoom (o getBoundingClientRect já vem esticado).
    const stretch = zoomStretch();
    const surface = api.canvasElement.element.getBoundingClientRect();
    const page = sheet.getBoundingClientRect();
    const left = (surface.left - page.left) / stretch;
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

  function afterRender(next) {
    if (next !== state.next) {
      return;    // um desenho descartado (veio outro depois)
    }
    if (state.measuring) {
      state.before = measureBefore(next.api);
      render(true);
      return;
    }
    // A camada nova entra no lugar da que estava na tela.
    state.next = null;
    if (state.api) {
      state.api.destroy();
    }
    if (tabElement !== next.element) {
      tabElement.remove();
    }
    state.api = next.api;
    tabElement = next.element;
    tabElement.classList.remove("pending");
    state.renderedSpan = next.span;
    if (state.page) {
      afterPageRender();
      return;
    }
    // O desenho novo já está na escala de agora: a #sheet perde o esticamento antes de medir (com ele, a margem da
    // esquerda saía multiplicada pelo zoom e a TAB descolava da Fita).
    sheet.style.transform = `translate3d(${-state.scroll}px, 0, 0)` +
      (zoomStretch() !== 1 ? ` scaleX(${zoomStretch()})` : "");
    state.anchors = collectAnchors(next.api);
    const width = Math.ceil(lead() + tabElement.scrollWidth + viewport.clientWidth * (1 - core.CURSOR_AT));
    sheet.style.width = width + "px";
    // As camadas são absolutas: a altura da pauta vem da camada na tela.
    sheet.style.height = Math.ceil(tabElement.scrollHeight) + "px";
    drawLoop();
    drawSelection();
    drawDurations();
    draw(true);
    post({
      type: "rendered",
      bars: state.score ? state.score.masterBars.length : 0,
      height: Math.ceil(tabElement.scrollHeight),
      ms: Math.round(performance.now() - state.renderStarted),
    });
  }

  // O desenho em páginas na tela: a folha na largura da janela, as batidas da pista principal para o cursor.
  function afterPageRender() {
    state.layoutWidth = viewport.clientWidth;
    sheet.style.width = "100%";
    sheet.style.height = Math.ceil(tabElement.scrollHeight) + "px";
    state.anchors = [];
    cursor.hidden = true;
    loopBox.hidden = true;
    const staff = state.score.tracks[shownTracks()[0]].staves.find((s) => s.tuning && s.tuning.length)
      || state.score.tracks[shownTracks()[0]].staves[0];
    const beats = [];
    for (const bar of staff.bars) {
      for (const beat of bar.voices[0].beats) beats.push(beat);
    }
    beats.sort((a, b) => a.absolutePlaybackStart - b.absolutePlaybackStart);
    state.pageBeats = beats;
    state.pageTicks = beats.map((b) => b.absolutePlaybackStart);
    state.pageSystem = null;
    drawSelection();
    drawLoop();
    drawPage(true);
    post({
      type: "rendered",
      bars: state.score.masterBars.length,
      height: Math.ceil(tabElement.scrollHeight),
      ms: Math.round(performance.now() - state.renderStarted),
    });
  }

  // O cursor do modo página: anda contínuo como o da faixa, de uma nota à seguinte no tempo (até o fim do sistema
  // quando a seguinte está no próximo), na altura do sistema. Quando entra num sistema novo, a página rola até ele
  // ficar no alto (antes pulava de nota em nota e só rolava quando o sistema já tinha saído da vista).
  function drawPage(force, now = performance.now()) {
    const api = state.api;
    const lookup = api && api.renderer.boundsLookup;
    if (!lookup || !state.points.length || !state.pageBeats.length) {
      pageCursor.hidden = true;
      return;
    }
    const tick = core.secondsToTick(state.points, core.estimate(state.clock, now, state.loop));
    // Antes da primeira batida (a introdução do vídeo), o cursor espera nela.
    const index = Math.max(0, core.beatIndexAt(state.pageTicks, tick));
    const bounds = lookup.findBeat(state.pageBeats[index]);
    if (!bounds) {
      pageCursor.hidden = true;
      return;
    }
    const systemBounds = bounds.barBounds.masterBarBounds.staffSystemBounds;
    const system = systemBounds.visualBounds;
    let x = bounds.onNotesX;
    const nextBeat = state.pageBeats[index + 1];
    const next = nextBeat ? lookup.findBeat(nextBeat) : null;
    const from = state.pageTicks[index];
    const to = nextBeat ? state.pageTicks[index + 1] : from;
    if (to > from && tick > from) {
      const sameSystem = next && next.barBounds.masterBarBounds.staffSystemBounds === systemBounds;
      const end = sameSystem ? next.onNotesX : system.x + system.w;
      x += (end - x) * Math.min(1, (tick - from) / (to - from));
    }
    const surface = api.canvasElement.element.getBoundingClientRect();
    const page = sheet.getBoundingClientRect();
    const left = surface.left - page.left + x;
    const top = surface.top - page.top + system.y;
    pageCursor.hidden = false;
    pageCursor.style.transform = `translate3d(${left}px, ${top}px, 0)`;
    pageCursor.style.height = system.h + "px";
    if (force || systemBounds !== state.pageSystem) {
      state.pageSystem = systemBounds;
      const view = viewport.scrollTop;
      const wanted = Math.max(0, top - 16);
      const outside = top < view || top + system.h > view + viewport.clientHeight;
      if (force ? outside : Math.abs(view - wanted) > 2) {
        viewport.scrollTo({ top: wanted, behavior: force ? "auto" : "smooth" });
      }
    }
  }

  // O loop no modo página (tiques [a, b), ou nil): as batidas da pista principal dentro dele, juntas por sistema, num
  // sombreado de cada sistema da altura dele. `preview`: o trecho sendo arrastado (borda tracejada).
  function drawPageLoop(range, preview = false) {
    pageLoop.innerHTML = "";
    pageLoop.classList.toggle("preview", preview);
    const api = state.api;
    const lookup = api && api.renderer.boundsLookup;
    if (!range || !lookup || !state.pageBeats.length) return;
    const [a, b] = range;
    const parts = new Map();
    state.pageBeats.forEach((beat, i) => {
      const tick = state.pageTicks[i];
      if (tick < a - 1e-6 || tick >= b - 1e-6) return;
      const bounds = lookup.findBeat(beat);
      if (!bounds) return;
      const system = bounds.barBounds.masterBarBounds.staffSystemBounds;
      const box = bounds.realBounds;
      const part = parts.get(system) || { left: Infinity, right: -Infinity, system };
      part.left = Math.min(part.left, box.x);
      part.right = Math.max(part.right, box.x + box.w);
      parts.set(system, part);
    });
    const surface = api.canvasElement.element.getBoundingClientRect();
    const page = sheet.getBoundingClientRect();
    for (const part of parts.values()) {
      const area = part.system.visualBounds;
      const div = document.createElement("div");
      div.className = "loop-part";
      div.style.left = surface.left - page.left + part.left + "px";
      div.style.width = part.right - part.left + "px";
      div.style.top = surface.top - page.top + area.y + "px";
      div.style.height = area.h + "px";
      pageLoop.appendChild(div);
    }
  }

  // Em páginas, arrastar de uma batida a outra marca o loop (o app prende nas batidas do mapa); um clique só leva a
  // música até a batida.
  function beatUnder(event) {
    const api = state.api;
    const lookup = api && api.renderer.boundsLookup;
    if (!lookup) return null;
    const surface = api.canvasElement.element.getBoundingClientRect();
    return lookup.getBeatAtPos(event.clientX - surface.left, event.clientY - surface.top);
  }

  sheet.addEventListener("pointerdown", (event) => {
    if (!state.page || event.button !== 0 || !state.points.length) return;
    // Na edição, uma nota sob o mouse é para escolher; fora dela o arrasto marca o loop também.
    if (state.editing && noteAt(event)) return;
    const beat = beatUnder(event);
    if (!beat) return;
    state.pageDrag = { first: beat, last: beat, x: event.clientX, y: event.clientY, moved: false };
    try {
      sheet.setPointerCapture(event.pointerId);
    } catch {
      // Sem captura, o arrasto vale enquanto o ponteiro fica sobre a página.
    }
  });

  function pageDragRange(drag) {
    const ends = [drag.first, drag.last].map((b) => [b.absolutePlaybackStart, b.absolutePlaybackStart + b.playbackDuration]);
    return [Math.min(ends[0][0], ends[1][0]), Math.max(ends[0][1], ends[1][1])];
  }

  sheet.addEventListener("pointermove", (event) => {
    const drag = state.pageDrag;
    if (!drag) return;
    if (!drag.moved && Math.hypot(event.clientX - drag.x, event.clientY - drag.y) < 6) return;
    drag.moved = true;
    drag.last = beatUnder(event) || drag.last;
    drawPageLoop(pageDragRange(drag), true);
  });

  function endPageDrag() {
    const drag = state.pageDrag;
    if (!drag) return;
    state.pageDrag = null;
    if (!drag.moved) return;
    state.suppressClick = true;
    const [a, b] = pageDragRange(drag);
    post({ type: "loop", start: core.tickToSeconds(state.points, a), end: core.tickToSeconds(state.points, b) });
    drawLoop();
  }

  sheet.addEventListener("pointerup", endPageDrag);
  sheet.addEventListener("pointercancel", endPageDrag);

  // Quanto a camada na tela está esticada: com o zoom mudando, o desenho antigo na escala nova até o novo chegar.
  function zoomStretch() {
    return state.renderedSpan > 0 && state.span > 0 ? state.renderedSpan / state.span : 1;
  }

  // O x de um segundo na tela (coordenadas de #sheet já esticadas pelo zoom em curso).
  function xAtSeconds(seconds) {
    if (!state.points.length || !state.anchors.length) {
      return null;
    }
    const drawn = core.xAtSeconds(state.points, state.anchors, seconds, state.layoutWidth / state.renderedSpan);
    return drawn * zoomStretch();
  }

  // O cursor fica na fração da largura que o app manda (`cursorAt`, como a agulha da Fita) e a pauta corre sob ele;
  // com a música num loop que tem pino, a pauta fica parada nele e só o cursor anda (core.windowStart). A pauta anda por `transform` (frações de pixel, na GPU; `scrollLeft`
  // arredonda e alterna passos de 1 e 2 px) e o cursor fica fora dela. `now`: a hora do quadro
  // (requestAnimationFrame), para os passos saírem iguais.
  function draw(force, now = performance.now()) {
    if (state.page) {
      drawPage(force, now);
      return;
    }
    const seconds = core.estimate(state.clock, now, state.loop);
    const x = xAtSeconds(seconds);
    if (x === null) {
      cursor.hidden = true;
      return;
    }
    const playing = state.clock && state.clock.playing;
    const width = viewport.clientWidth;
    const outside = x < state.scroll || x > state.scroll + width;
    const fixed = state.hold !== null ? state.hold : core.windowStart(seconds, state.loop, state.pin);
    if (playing || force || outside || fixed !== null) {
      const target = fixed === null ? core.scrollFor(x, width, state.cursorAt) : xAtSeconds(fixed);
      if (force || Math.abs(target - state.scroll) >= 0.01) {
        const stretch = zoomStretch();
        sheet.style.transform = `translate3d(${-target}px, 0, 0)` + (stretch !== 1 ? ` scaleX(${stretch})` : "");
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
    if (state.page) {
      loopBox.hidden = true;
      drawPageLoop(state.loop && state.points.length
        ? [core.secondsToTick(state.points, state.loop[0]), core.secondsToTick(state.points, state.loop[1])] : null);
      return;
    }
    pageLoop.innerHTML = "";
    if (!state.loop) {
      loopBox.hidden = true;
      return;
    }
    // Dentro de #sheet, em coordenadas do desenho: o esticamento do zoom vem do transform da própria #sheet.
    const a = xAtSeconds(state.loop[0]) / zoomStretch();
    const b = xAtSeconds(state.loop[1]) / zoomStretch();
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
    if (state.suppressClick) {
      state.suppressClick = false;
      return;
    }
    // Em qualquer caso o cabeçote vai até ali; na edição o clique também escolhe a nota (depois do seek: a nota
    // clicada toca, e um seek depois a calaria).
    if (state.page) {
      // Em páginas: a música vai até a batida clicada.
      const beat = state.points.length ? beatUnder(event) : null;
      if (beat) post({ type: "seek", seconds: Math.max(0, core.tickToSeconds(state.points, beat.absolutePlaybackStart)) });
    } else {
      seekAtClick(event);
    }
    if (state.editing) pick(event);
  });

  // O tempo sob um ponto da tela (na faixa: pelas âncoras das batidas desenhadas).
  function secondsAtClient(clientX) {
    if (!state.anchors.length || !state.points.length) return null;
    const page = sheet.getBoundingClientRect();
    const tick = core.tickAtX(state.anchors, (clientX - page.left) / zoomStretch());
    return core.tickToSeconds(state.points, tick);
  }

  // O cabeçote vai para onde o mouse clicou: a música até ali e o cursor naquela fração da largura (a pauta não
  // salta; tocando, ela segue com o cursor nesse lugar). O app faz o mesmo com a Fita.
  function seekAtClick(event) {
    const seconds = secondsAtClient(event.clientX);
    if (seconds === null) return;
    const box = viewport.getBoundingClientRect();
    const at = Math.min(0.95, Math.max(0.05, (event.clientX - box.left) / Math.max(1, box.width)));
    post({ type: "seek", seconds: Math.max(0, seconds), at });
  }

  // Na faixa, clicar e arrastar fora de uma nota (também na edição) marca o loop: a prévia acompanha o mouse e, ao
  // soltar, o app prende nas batidas como na Fita.
  sheet.addEventListener("pointerdown", (event) => {
    if (state.page || event.button !== 0 || event.shiftKey || !state.anchors.length) return;
    if (event.target.closest && event.target.closest(".duration")) return;
    if (state.editing && noteAt(event)) return;
    state.loopDrag = { from: event.clientX, moved: false };
    try {
      sheet.setPointerCapture(event.pointerId);
    } catch {
      // Sem captura, o arrasto vale enquanto o ponteiro fica sobre a pauta.
    }
  });

  sheet.addEventListener("pointermove", (event) => {
    const drag = state.loopDrag;
    if (!drag) return;
    if (!drag.moved && Math.abs(event.clientX - drag.from) < 5) return;
    drag.moved = true;
    const a = secondsAtClient(Math.min(drag.from, event.clientX));
    const b = secondsAtClient(Math.max(drag.from, event.clientX));
    if (a === null || b === null) return;
    const x0 = xAtSeconds(a) / zoomStretch();
    const x1 = xAtSeconds(b) / zoomStretch();
    loopBox.hidden = false;
    loopBox.classList.add("preview");
    loopBox.style.left = x0 + "px";
    loopBox.style.width = Math.max(1, x1 - x0) + "px";
    drag.range = [a, b];
  });

  function endLoopDrag() {
    const drag = state.loopDrag;
    if (!drag) return;
    state.loopDrag = null;
    loopBox.classList.remove("preview");
    if (!drag.moved || !drag.range) return;
    state.suppressClick = true;
    post({ type: "loop", start: Math.max(0, drag.range[0]), end: drag.range[1] });
    drawLoop();
  }

  sheet.addEventListener("pointerup", endLoopDrag);
  sheet.addEventListener("pointercancel", endLoopDrag);

  // ⇧ + arrastar, no Ajuste: nada se mexe na pauta; o app desliza a onda da Fita com o mouse.
  sheet.addEventListener("pointerdown", (event) => {
    if (state.page || !state.adjusting || !event.shiftKey || !state.anchors.length) {
      return;
    }
    state.shiftDrag = { from: event.clientX, dx: 0 };
    try {
      sheet.setPointerCapture(event.pointerId);
    } catch {
      // Sem captura o arrasto ainda funciona enquanto o ponteiro fica sobre a pauta.
    }
    sheet.classList.add("dragging");
    event.preventDefault();
  });

  sheet.addEventListener("pointermove", (event) => {
    if (!state.shiftDrag) {
      return;
    }
    state.shiftDrag.dx = event.clientX - state.shiftDrag.from;
    post({ type: "shift", seconds: state.shiftDrag.dx / (state.layoutWidth / state.span) });
  });

  function endShiftDrag() {
    const drag = state.shiftDrag;
    if (!drag) {
      return;
    }
    state.shiftDrag = null;
    sheet.classList.remove("dragging");
    const moved = Math.abs(drag.dx) > 3;
    state.suppressClick = moved;
    const seconds = drag.dx / (state.layoutWidth / state.span);
    post(moved ? { type: "shiftEnd", seconds } : { type: "shift", seconds: 0 });
  }

  sheet.addEventListener("pointerup", endShiftDrag);
  sheet.addEventListener("pointercancel", endShiftDrag);

  // MARK: a edição da TAB

  // A nota sob o clique (pelas caixas das notas do alphaTab); um clique fora de nota tira a escolha.
  function pick(event) {
    const api = state.api;
    if (!api || !api.renderer.boundsLookup) {
      return;
    }
    const surface = api.canvasElement.element.getBoundingClientRect();
    const x = (event.clientX - surface.left) / zoomStretch();
    const y = event.clientY - surface.top;
    const lookup = api.renderer.boundsLookup;
    // A nota sob o clique, também a ligada que a TAB não mostra (`noteAt`).
    const note = noteAt(event);
    const beat = note ? note.beat : lookup.getBeatAtPos(x, y);
    // ⇧: da nota de partida até esta, todas no meio; ⌘: põe ou tira só esta; sem tecla, só esta.
    const found = note ? edit.resolve(state.score, edit.pathOf(note)) : null;
    if (found && event.shiftKey && selectedNote()) {
      extendTo(found);
    } else if (found && event.metaKey && selectedNote()) {
      toggleInGroup(found);
    } else {
      choose(found ? edit.pathOf(found) : null);
      // Sem nota sob o clique, numa linha da TAB: o cursor de inserção naquela corda da batida.
      const string = !found && beat ? stringAt(beat, y) : null;
      if (string) placeCaret(beat, string, event);
      // O clique numa nota a faz soar (o som gravado dela; o botão direito, a sintetizada).
      if (found) hear(found, false);
    }
    drawSelection();
    postSelection();
  }

  // O cursor de inserção na corda do clique. Na faixa, no tempo do clique (na grade, contada do começo do compasso):
  // no começo de uma batida, o cursor é o dela (acorde ou pausa); no meio de uma nota longa ou de uma pausa, guarda o
  // tique também (a nota nova divide a longa, ou entra no meio da pausa).
  function placeCaret(beat, string, event) {
    const target = edit.resolveBeat(state.score, edit.caretOf(beat, string));
    if (!target) return;
    let tick = null;
    if (!state.page && state.anchors.length && state.grid > 0) {
      const page = sheet.getBoundingClientRect();
      const raw = core.tickAtX(state.anchors, (event.clientX - page.left) / zoomStretch());
      const master = masterAt(raw);
      if (master) tick = master.start + Math.round((raw - master.start) / state.grid) * state.grid;
    }
    const staff = target.voice.bar.staff;
    const voiceIndex = target.voice.index;
    const bar = tick === null ? null : staff.bars.find((b) => b.masterBar.start <= tick + 0.5
      && tick < b.masterBar.start + b.masterBar.calculateDuration() - 0.5);
    const holder = bar && bar.voices[voiceIndex] && bar.voices[voiceIndex].beats.find((b) =>
      b.absolutePlaybackStart <= tick + 0.5 && tick < b.absolutePlaybackStart + b.playbackDuration - 0.5);
    if (state.caretVoice > 0) {
      // Na voz 2 a nota nova entra sempre no tique (a voz 2 tem as batidas dela).
      const at = holder || target;
      state.caret = [...edit.caretOf(at, string), tick === null ? at.absolutePlaybackStart : tick, state.caretVoice];
      return;
    }
    if (!holder || Math.abs(holder.absolutePlaybackStart - tick) < 1) {
      const at = holder || target;
      if (!at.notes.some((n) => n.string === string)) state.caret = edit.caretOf(at, string);
      return;
    }
    state.caret = [...edit.caretOf(holder, string), tick];
  }

  // Um som sem nota escrita (o app achou no espectro): o cursor de inserção no tique dele, na grade, na corda em que a
  // altura cai mais à mão (a casa mais perto da nota escrita mais próxima no tempo), com a casa sugerida.
  function caretAtPitch(value) {
    const track = state.score && state.score.tracks[value.track];
    const staff = track && track.staves.find((s) => s.tuning && s.tuning.length);
    if (!staff) return;
    const master = masterAt(value.tick);
    if (!master) return;
    const tick = master.start + Math.round((value.tick - master.start) / state.grid) * state.grid;
    const bar = staff.bars[master.index];
    const voice = bar && bar.voices[0];
    const holder = voice && voice.beats.find((b) => b.absolutePlaybackStart <= tick + 0.5
      && tick < b.absolutePlaybackStart + b.playbackDuration - 0.5);
    if (!holder) return;
    const at = Math.abs(holder.absolutePlaybackStart - tick) < 1;
    const notes = edit.notesOf(staff);
    let nearest = null;
    for (const n of notes) {
      if (!nearest || Math.abs(n.beat.absolutePlaybackStart - tick) < Math.abs(nearest.beat.absolutePlaybackStart - tick)) nearest = n;
    }
    const reference = nearest ? nearest.fret : 5;
    const count = staff.tuning.length;
    let best = null;
    for (let alpha = 1; alpha <= count; alpha++) {
      const fret = value.pitch - staff.tuning[count - alpha];
      if (fret < 0 || fret > edit.MAX_FRET) continue;
      if (at && holder.notes.some((n) => n.string === alpha)) continue;
      if (!best || Math.abs(fret - reference) < Math.abs(best.fret - reference)) best = { alpha, fret };
    }
    if (!best) {
      post({ type: "notice", text: "Essa altura não cabe em nenhuma corda livre aqui." });
      return;
    }
    choose(null);
    state.caret = at ? edit.caretOf(holder, best.alpha) : [...edit.caretOf(holder, best.alpha), tick];
    state.suggestedFret = best.fret;
    drawSelection();
    postSelection();
  }

  // O compasso da escolha (da nota principal ou do cursor de inserção), ou null.
  function chosenBar() {
    if (state.caret) {
      const beat = edit.resolveBeat(state.score, state.caret);
      const tick = state.caret.length > 6 && state.caret[6] !== null ? state.caret[6] : beat && beat.absolutePlaybackStart;
      const master = tick === null || tick === undefined ? null : masterAt(tick);
      return master ? master.index : null;
    }
    const note = selectedNote();
    return note ? note.beat.voice.bar.index : null;
  }

  // Os compassos para o app: quantos, onde cada um começa (mais o fim do último: a Fita desenha por eles) e as seções
  // do Guitar Pro (Intro, Verse 1…), de que o app faz trechos de estudo.
  function barInfo() {
    const masters = state.score.masterBars;
    const last = masters[masters.length - 1];
    return {
      bars: masters.length,
      barTicks: masters.map((m) => m.start).concat(last ? [last.start + last.calculateDuration()] : []),
      sections: masters
        .filter((m) => m.section && (m.section.text || m.section.marker))
        .map((m) => ({ tick: m.start, name: m.section.text || m.section.marker })),
    };
  }

  // Pôr um compasso antes ou depois do da escolha, apagá-lo ou mudar a fórmula dele, em todas as pistas. O mapa de
  // tempo acompanha (o que vem depois fica no mesmo lugar do áudio) e vai ao app com os compassos novos; o Desfazer
  // volta os dois.
  function barEdit(value) {
    const index = chosenBar();
    if (index === null || !value) {
      post({ type: "notice", text: "Escolha uma nota ou uma linha da TAB no compasso." });
      return;
    }
    let info = null;
    let reason = null;
    change((step) => {
      let result;
      if (value.action === "insert-before") result = edit.insertBar(alphaTab, state.score, index);
      else if (value.action === "insert-after") result = edit.insertBar(alphaTab, state.score, index + 1);
      else if (value.action === "delete") result = edit.deleteBar(alphaTab, state.score, index);
      else if (value.action === "signature") {
        result = edit.setTimeSignature(alphaTab, state.score, index, value.numerator, value.denominator);
      }
      if (!result || typeof result === "string") {
        reason = result || "missing";
        return false;
      }
      const kind = value.action === "delete" ? "delete" : value.action === "signature" ? "signature" : "insert";
      const bar = value.action === "insert-after" ? index + 1 : index;
      info = { tick: result.tick, oldLength: result.oldLength, newLength: result.newLength, bar, kind };
      // O passo do Desfazer volta a mudança ao contrário.
      step.change = { ...info, oldLength: info.newLength, newLength: info.oldLength,
        kind: { insert: "delete", delete: "insert", signature: "signature" }[kind] };
      state.score = result.score;
      state.points = core.reshapePoints(state.points, info.tick, info.oldLength, info.newLength);
      // Os compassos mudaram: a clave e as fórmulas de cada um são medidas de novo no próximo desenho.
      state.before = null;
      return true;
    });
    if (reason) {
      const text = { last: "A música não fica sem compasso.", signature: "Fórmula de compasso inválida.",
        grace: RETIME_REASONS.grace, figure: "O compasso não cabe em figuras nessa fórmula." }[reason];
      post({ type: "notice", text: text || "Não deu para mudar o compasso." });
      return;
    }
    choose(null);
    drawSelection();
    postSelection();
    post({ type: "structure", points: state.points, change: info, ...barInfo() });
    const what = { insert: "Compasso posto", delete: "Compasso apagado", signature: "Fórmula mudada" }[info.kind];
    post({ type: "notice", text: `${what} · o mapa de tempo acompanhou · ⌘Z desfaz` });
  }

  // O compasso (do score) em que um tique cai.
  function masterAt(tick) {
    const masters = state.score ? state.score.masterBars : [];
    let master = masters[0] || null;
    for (const m of masters) if (m.start <= tick + 0.5) master = m;
    return master;
  }

  // A corda (do alphaTab) da linha da TAB sob `y` na batida, ou null fora das linhas: as cordas ficam igualmente
  // espaçadas na caixa do compasso da pauta (a de cima é a mais aguda).
  function stringAt(beat, y) {
    const lookup = state.api && state.api.renderer.boundsLookup;
    const bounds = lookup && lookup.findBeat(beat);
    const staff = beat.voice.bar.staff;
    const count = staff.tuning ? staff.tuning.length : 0;
    if (!bounds || !bounds.barBounds || count < 2) return null;
    const box = bounds.barBounds.visualBounds;
    const spacing = box.h / (count - 1);
    const line = Math.round((y - box.y) / spacing);
    if (line < 0 || line >= count || Math.abs(y - (box.y + line * spacing)) > spacing * 0.6) return null;
    return count - line;
  }

  // Manda tocar uma nota: o trecho dela (com as ligadas) no som gravado, ou sintetizada (`synth`) com a altura e as
  // formas da escrita.
  function hear(note, synth) {
    const span = edit.span(note);
    post({ type: "hear", synth, track: note.beat.voice.bar.staff.track.index, tick: note.beat.absolutePlaybackStart,
      string: edit.tabString(note), pitch: note.realValue,
      from: span ? span.start : note.beat.absolutePlaybackStart,
      to: span ? span.end : note.beat.absolutePlaybackStart + note.beat.playbackDuration });
  }

  // O botão direito numa nota: ela soa sintetizada (na edição, também a escolhe). O menu da página não abre.
  sheet.addEventListener("contextmenu", (event) => {
    event.preventDefault();
    const hit = noteAt(event);
    const note = hit && state.score ? edit.resolve(state.score, edit.pathOf(hit)) : null;
    if (!note) return;
    if (state.editing) {
      choose(edit.pathOf(note));
      drawSelection();
      postSelection();
    }
    hear(note, true);
  });

  function selectedNote() {
    return state.score ? edit.resolve(state.score, state.selected) : null;
  }

  const samePath = (a, b) => Boolean(a && b) && JSON.stringify(a) === JSON.stringify(b);

  // Uma nota só (ou nenhuma).
  function choose(path) {
    state.selected = path;
    state.group = null;
    state.anchor = path;
    state.caret = null;
    state.suggestedFret = null;
  }

  // As notas escolhidas, a principal primeiro e as outras em ordem de tempo.
  function selectedNotes() {
    const main = selectedNote();
    if (!main) return [];
    if (!state.group) return [main];
    const others = state.group.map((p) => edit.resolve(state.score, p)).filter((n) => n && n !== main);
    return [main, ...others];
  }

  // ⇧: da nota de partida (`anchor`) até `note`, na ordem de tempo da pauta; a principal passa a ser `note`.
  function extendTo(note) {
    const from = (state.anchor && edit.resolve(state.score, state.anchor)) || selectedNote();
    const range = from ? edit.rangeOf(from, note) : [];
    if (range.length < 2) {
      choose(edit.pathOf(note));
      return;
    }
    state.anchor = edit.pathOf(from);
    state.selected = edit.pathOf(note);
    state.group = range.map((n) => edit.pathOf(n));
  }

  // ⌘: põe ou tira uma nota; tirar a principal passa o papel para a última que sobrou.
  function toggleInGroup(note) {
    const path = edit.pathOf(note);
    const group = state.group ? state.group.slice() : [state.selected];
    const index = group.findIndex((p) => samePath(p, path));
    if (index >= 0) {
      if (group.length === 1) return;
      group.splice(index, 1);
      if (samePath(state.selected, path)) state.selected = group[group.length - 1];
    } else {
      group.push(path);
      state.selected = path;
    }
    state.group = group.length > 1 ? group : null;
  }

  // Onde cada nota escolhida está (pista, tique, corda), para achá-las de novo depois de um compasso refeito.
  function wheresOf(notes) {
    return notes.map((n) => ({ track: n.beat.voice.bar.staff.track.index, tick: n.beat.absolutePlaybackStart,
      string: edit.tabString(n) }));
  }

  // A escolha de novo pelos lugares (a primeira é a principal); as que sumiram ficam de fora.
  function chooseWheres(wheres) {
    const found = wheres.map((w) => edit.findNote(state.score, w.track, w.tick, w.string)).filter(Boolean);
    if (!found.length) {
      choose(null);
      return;
    }
    choose(edit.pathOf(found[0]));
    if (found.length > 1) state.group = found.map((n) => edit.pathOf(n));
  }

  // O destaque da nota escolhida, em coordenadas de #sheet (as do desenho; o zoom vem do transform da #sheet).
  function drawSelection() {
    drawGroup();
    drawCaret();
    const note = state.editing ? selectedNote() : null;
    // A barra de duração da nota escolhida acende.
    for (const bar of durationLayer.children) bar.classList.toggle("chosen", Boolean(note) && bar.beat === note.beat);
    const bounds = note && state.api && state.api.renderer.boundsLookup && state.api.renderer.boundsLookup.findBeat(note.beat);
    const head = bounds && bounds.notes ? bounds.notes.find((b) => b.note === note) : null;
    if (!head) {
      selectionBox.hidden = true;
      return;
    }
    const surface = state.api.canvasElement.element.getBoundingClientRect();
    const page = sheet.getBoundingClientRect();
    const stretch = zoomStretch();
    let box = head.noteHeadBounds;
    const count = note.beat.voice.bar.staff.tuning.length;
    if (box.w < 4 && bounds.barBounds && count > 1) {
      // A ligada que a TAB não mostra: a caixa do tamanho de um número, na linha da corda, no x das notas da batida.
      const lines = bounds.barBounds.visualBounds;
      const y = lines.y + (count - note.string) * (lines.h / (count - 1));
      box = { x: bounds.onNotesX - 7, y: y - 8, w: 14, h: 16 };
    }
    selectionBox.hidden = false;
    selectionBox.style.left = (surface.left - page.left) / stretch + box.x - 3 + "px";
    selectionBox.style.top = surface.top - page.top + box.y - 3 + "px";
    selectionBox.style.width = box.w + 6 + "px";
    selectionBox.style.height = box.h + 6 + "px";
  }

  // O cursor de inserção: uma caixa na linha da corda, no x das notas da batida.
  function drawCaret() {
    if (!caretBox.parentNode) sheet.appendChild(caretBox);
    const beat = state.editing && state.caret && state.score ? edit.resolveBeat(state.score, state.caret) : null;
    const lookup = state.api && state.api.renderer.boundsLookup;
    const bounds = beat && lookup ? lookup.findBeat(beat) : null;
    const staff = beat && beat.voice.bar.staff;
    const count = staff && staff.tuning ? staff.tuning.length : 0;
    if (!bounds || !bounds.barBounds || count < 2) {
      caretBox.hidden = true;
      return;
    }
    const surface = state.api.canvasElement.element.getBoundingClientRect();
    const page = sheet.getBoundingClientRect();
    const stretch = zoomStretch();
    const box = bounds.barBounds.visualBounds;
    const y = box.y + (count - state.caret[5]) * (box.h / (count - 1));
    // No meio de uma nota ou pausa, no x do tique (a faixa é tempo); senão, no x das notas da batida.
    const timed = state.caret.length > 6 ? xAtSeconds(core.tickToSeconds(state.points, state.caret[6])) : null;
    caretBox.hidden = false;
    caretBox.style.left = (timed !== null ? timed / stretch : (surface.left - page.left) / stretch + bounds.onNotesX) - 7 + "px";
    caretBox.style.top = surface.top - page.top + y - 8 + "px";
  }

  // Os contornos das outras notas escolhidas.
  function drawGroup() {
    if (!groupLayer.parentNode) sheet.appendChild(groupLayer);
    groupLayer.innerHTML = "";
    const lookup = state.api && state.api.renderer.boundsLookup;
    if (!state.editing || !state.group || !lookup) return;
    const surface = state.api.canvasElement.element.getBoundingClientRect();
    const page = sheet.getBoundingClientRect();
    const stretch = zoomStretch();
    const main = selectedNote();
    for (const note of selectedNotes()) {
      if (note === main) continue;
      const bounds = lookup.findBeat(note.beat);
      const head = bounds && bounds.notes ? bounds.notes.find((b) => b.note === note) : null;
      if (!head) continue;
      const box = head.noteHeadBounds;
      const mark = document.createElement("div");
      mark.className = "group-note";
      mark.style.left = (surface.left - page.left) / stretch + box.x - 3 + "px";
      mark.style.top = surface.top - page.top + box.y - 3 + "px";
      mark.style.width = box.w + 6 + "px";
      mark.style.height = box.h + 6 + "px";
      groupLayer.appendChild(mark);
    }
  }

  function postSelection() {
    const note = selectedNote();
    const notes = selectedNotes();
    // Com várias, quantas são e o trecho delas (do começo da primeira ao fim da última, com as ligadas), para o Ouvir.
    let from = Infinity;
    let to = -Infinity;
    for (const n of notes) {
      const span = edit.span(n);
      if (!span) continue;
      from = Math.min(from, span.start);
      to = Math.max(to, span.end);
    }
    const first = notes.reduce((a, n) => (!a || n.beat.absolutePlaybackStart < a.beat.absolutePlaybackStart ? n : a), null);
    const last = notes.reduce((a, n) => (!a || n.beat.absolutePlaybackStart > a.beat.absolutePlaybackStart ? n : a), null);
    const caretBeat = state.caret && state.score ? edit.resolveBeat(state.score, state.caret) : null;
    post({
      type: "selection",
      caret: caretBeat ? { place: placeName(state.caret.length > 6 ? state.caret[6] : caretBeat.absolutePlaybackStart),
        string: caretBeat.voice.bar.staff.tuning.length - state.caret[5] + 1, rest: caretBeat.notes.length === 0,
        inside: state.caret.length > 6 && Math.abs(state.caret[6] - caretBeat.absolutePlaybackStart) >= 1,
        voice: (state.caret[7] || 0) + 1, figure: edit.figureName(caretBeat.playbackDuration),
        fret: state.suggestedFret } : null,
      bar: (() => {
        const index = state.score ? chosenBar() : null;
        const master = index === null ? null : state.score.masterBars[index];
        return master ? { index, numerator: master.timeSignatureNumerator, denominator: master.timeSignatureDenominator }
          : null;
      })(),
      note: note ? Object.assign(edit.describe(alphaTab, note), {
        place: placeName(note.beat.absolutePlaybackStart),
        count: notes.length,
        from: Number.isFinite(from) ? from : null,
        to: Number.isFinite(to) ? to : null,
        span: notes.length > 1 ? `${placeName(first.beat.absolutePlaybackStart)} → ${placeName(last.beat.absolutePlaybackStart)}` : null,
      }) : null,
      canUndo: state.undo.length > 0,
      canRedo: state.redo.length > 0,
    });
  }

  // Uma mudança na partitura: o passo do Desfazer antes, a cópia (o finish) depois, o desenho novo, a gravação adiada.
  function change(apply) {
    const before = { score: edit.snapshot(alphaTab, state.score), selected: state.selected, group: state.group,
      anchor: state.anchor, points: state.points, change: null };
    let next = null;
    let failure = null;
    try {
      next = apply(before) ? edit.refinish(alphaTab, state.score) : null;
    } catch (error) {
      failure = error;
    }
    if (!next) {
      // Uma mudança que não deu pode ter mexido em parte (várias notas, um compasso refeito pela metade): volta tudo.
      // Também quando a cópia falha: a partitura pela metade não desenhava nem gravava mais nada depois.
      state.score = edit.restore(alphaTab, before.score);
      state.selected = before.selected;
      state.group = before.group;
      state.anchor = before.anchor;
      state.points = before.points;
      core.showPreferences(state.score);
      render();
      if (failure) throw failure;
      return;
    }
    state.undo.push(before);
    if (state.undo.length > UNDO_LIMIT) {
      state.undo.shift();
    }
    state.redo = [];
    replace(next);
  }

  // A partitura nova no lugar (editada, desfeita ou refeita): desenhada de novo nas mesmas larguras, gravada depois.
  function replace(score) {
    state.score = score;
    core.showPreferences(state.score);
    render();
    scheduleSave();
    postSelection();
  }

  function scheduleSave() {
    window.clearTimeout(state.saveTimer);
    state.saveTimer = window.setTimeout(() => {
      try {
        const bytes = edit.exportGp(alphaTab, state.score);
        let binary = "";
        for (let i = 0; i < bytes.length; i += 0x8000) {
          binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        }
        post({ type: "save", gp: btoa(binary) });
        post({ type: "notes", notes: core.trackNotes(state.score) });
      } catch (error) {
        report(error);
      }
    }, SAVE_MS);
  }

  function runEdit(op, value) {
    if (!state.score) {
      return;
    }
    if (op === "undo" || op === "redo") {
      const from = op === "undo" ? state.undo : state.redo;
      const to = op === "undo" ? state.redo : state.undo;
      if (!from.length) {
        return;
      }
      // Cada passo leva a nota escolhida de então: desfazer uma troca de corda volta a escolher a nota na corda antiga.
      const step = from.pop();
      // Um passo que mudou os compassos leva o mapa de tempo junto (e o app desfaz o que andou com ele).
      const reverse = step.change ? { ...step.change, oldLength: step.change.newLength, newLength: step.change.oldLength,
        kind: { insert: "delete", delete: "insert", signature: "signature" }[step.change.kind] } : null;
      to.push({ score: edit.snapshot(alphaTab, state.score), selected: state.selected, group: state.group,
        anchor: state.anchor, points: state.points, change: reverse });
      state.selected = step.selected;
      state.group = step.group || null;
      state.anchor = step.anchor || step.selected;
      state.caret = null;
      if (step.points && step.points !== state.points) {
        state.points = step.points;
        state.before = null;
        replace(edit.restore(alphaTab, step.score));
        // O que acontece agora é a mudança guardada no passo (a contrária da que ele desfaz).
        post({ type: "structure", points: state.points, change: step.change, ...barInfo() });
        return;
      }
      replace(edit.restore(alphaTab, step.score));
      return;
    }
    if (op === "clear") {
      choose(null);
      drawSelection();
      postSelection();
      return;
    }
    if (op === "select") {
      // A nota que a Fita apontou (pista, tique, corda).
      const found = value ? edit.findNote(state.score, value.track, value.tick, value.string) : null;
      choose(found ? edit.pathOf(found) : null);
      drawSelection();
      postSelection();
      return;
    }
    if (op === "paste") {
      pasteAt(value);
      return;
    }
    if (op === "bar") {
      barEdit(value);
      return;
    }
    if (op === "caretPitch") {
      caretAtPitch(value);
      return;
    }
    if (op === "split") {
      splitAt(value);
      return;
    }
    if (op === "voice") {
      // A voz da nota nova (1 ou 2): o cursor de inserção passa a pôr nela.
      state.caretVoice = value === 2 ? 1 : 0;
      if (state.caret) {
        const beat = edit.resolveBeat(state.score, state.caret);
        const tick = state.caret.length > 6 && state.caret[6] !== null ? state.caret[6] : beat ? beat.absolutePlaybackStart : null;
        state.caret = [...state.caret.slice(0, 6), state.caretVoice > 0 ? tick : state.caret[6] ?? null, state.caretVoice];
        if (state.caretVoice === 0 && beat && Math.abs(beat.absolutePlaybackStart - tick) < 1) state.caret = state.caret.slice(0, 6);
      }
      drawSelection();
      postSelection();
      return;
    }
    if (state.caret) {
      caretEdit(op, value);
      return;
    }
    const note = selectedNote();
    if (!note) {
      return;
    }
    const notes = selectedNotes();
    const several = notes.length > 1;
    switch (op) {
      case "copy":
      case "cut": {
        // O recorte vai ao app (a área de transferência: cola noutra música); recortar deixa pausa no lugar.
        const clip = edit.copy(notes);
        if (!clip) return;
        post({ type: "clip", clip, beats: clip.events.length, cut: op === "cut" });
        if (op === "cut") runEdit("rest");
        return;
      }
      case "single":
        // Esc com várias: fica só a principal.
        choose(state.selected);
        drawSelection();
        postSelection();
        return;
      case "nav": {
        const next = edit.neighbor(note, value > 0 ? 1 : -1);
        if (next) {
          choose(edit.pathOf(next));
          drawSelection();
          postSelection();
        }
        return;
      }
      case "extend": {
        // ⇧← ⇧→: a escolha cresce ou encolhe de nota em nota a partir da de partida.
        const next = edit.neighbor(note, value > 0 ? 1 : -1);
        if (next) {
          if (!state.anchor) state.anchor = state.selected;
          extendTo(next);
          drawSelection();
          postSelection();
        }
        return;
      }
      case "technique": {
        if (value === "tie") {
          // Ligada (L): todas passam a ser ligadas à anterior da corda, ou todas deixam, pela principal.
          const tied = note.isTieDestination;
          let reason = null;
          change(() => notes.filter((n) => n.isTieDestination === tied).every((n) => {
            const result = edit.tie(alphaTab, n);
            if (result !== true) reason = result;
            return result === true;
          }));
          if (reason) post({ type: "notice", text: "Não há nota na batida de antes, nessa corda, para ligar." });
          return;
        }
        change(() => (several ? edit.toggleAll(alphaTab, notes, value) : edit.toggle(alphaTab, note, value)));
        return;
      }
      case "fret":
        change(() => edit.setFret(note, value));
        return;
      case "string":
        // +1 sobe para a corda mais aguda: no alphaTab, a corda de número maior. Com várias, todas andam o mesmo.
        change(() => {
          const moved = several ? edit.moveAll(notes, value) : edit.moveString(note, value);
          if (moved) {
            state.selected = edit.pathOf(note);
            if (several) state.group = notes.map((n) => edit.pathOf(n));
            state.anchor = state.selected;
          } else if (several) {
            post({ type: "notice", text: "Uma das notas não cabe nessa corda (fora do braço ou corda ocupada)." });
          }
          return moved;
        });
        return;
      case "transpose":
        change(() => (several ? edit.transposeAll(notes, value) : edit.transpose(note, value)));
        return;
      case "fit":
        change(() => edit.fit(alphaTab, note, value));
        return;
      case "nudge": {
        // Um passo da grade (⌥← ⌥→, o arrasto lateral da Lente), mantendo a duração; com várias, todas andam juntas.
        const delta = Math.round(value) * state.grid;
        if (several) {
          eachBeat(notes, delta > 0, delta, (n) => {
            const span = edit.span(n);
            return span ? edit.retime(alphaTab, n, span.start + delta, span.end + delta) : "missing";
          });
          return;
        }
        retimeSelected(note, (span) => [span.start + delta, span.end + delta]);
        return;
      }
      case "retime":
        // Começo e fim novos em tiques (a barra de duração arrastada).
        retimeSelected(note, () => [value.start, value.end]);
        return;
      case "length": {
        // A figura nova (tiques), do mesmo começo; com várias, cada batida escolhida.
        if (several) {
          eachBeat(notes, false, 0, (n) => edit.setLength(alphaTab, n, value));
          return;
        }
        const span = edit.span(note);
        if (span) rewriteSelected(note, span.start, () => edit.setLength(alphaTab, note, value));
        return;
      }
      case "rest": {
        // A batida inteira (o acorde, as ligadas) vira pausa; a escolha passa para a nota seguinte.
        // A seguinte fora do acorde e das ligadas dela (ou, no fim, a anterior); com várias, depois da última.
        let span = edit.span(note);
        for (const n of notes) {
          const s = edit.span(n);
          if (s && span) span = { start: Math.min(span.start, s.start), end: Math.max(span.end, s.end) };
        }
        const list = edit.notesOf(note.beat.voice.bar.staff);
        const next = span && (list.find((n) => n.beat.absolutePlaybackStart >= span.end - 0.5)
          || list.slice().reverse().find((n) => n.beat.absolutePlaybackStart < span.start - 0.5));
        if (several) {
          eachBeat(notes, false, 0, (n) => edit.toRest(alphaTab, n), next ? wheresOf([next]) : []);
          return;
        }
        const where = next ? { track: next.beat.voice.bar.staff.track.index, string: edit.tabString(next),
          tick: next.beat.absolutePlaybackStart } : null;
        let reason = null;
        change(() => {
          const result = edit.toRest(alphaTab, note);
          if (result !== true) reason = result;
          return result === true;
        });
        if (reason) {
          post({ type: "notice", text: RETIME_REASONS[reason] || "Não deu para pôr a pausa." });
          return;
        }
        const found = where ? edit.findNote(state.score, where.track, where.tick, where.string) : null;
        choose(found ? edit.pathOf(found) : null);
        drawSelection();
        postSelection();
        return;
      }
      case "delete": {
        // Com várias, todas; a escolha passa para a nota depois da última (ou antes da primeira).
        const list = edit.notesOf(note.beat.voice.bar.staff);
        const chosen = new Set(notes);
        const indexes = notes.map((n) => list.indexOf(n)).filter((i) => i >= 0);
        const after = list.slice(Math.max(...indexes) + 1).find((n) => !chosen.has(n));
        const before = list.slice(0, Math.min(...indexes)).reverse().find((n) => !chosen.has(n));
        const target = after || before;
        const where = target ? wheresOf([target]) : [];
        change(() => notes.every((n) => edit.remove(n)));
        chooseWheres(where);
        drawSelection();
        postSelection();
        return;
      }
    }
  }

  window.addEventListener("resize", () => {
    draw(true);
    if (Math.abs(viewport.clientWidth - state.layoutWidth) > 1) {
      relayout();
    }
  });

  // Liga ou desliga o modo página: a folha volta ao começo e o cursor certo aparece.
  function setPage(value) {
    state.page = value;
    document.body.classList.toggle("page", value);
    pageCursor.hidden = true;
    cursor.hidden = value;
    state.before = null;
    state.scroll = 0;
    viewport.scrollTop = 0;
    if (!value) sheet.style.transform = "";
  }

  // A nota escolhida (a batida dela) com começo e fim novos: os compassos afetados são refeitos (edit.retime); a escolha
  // volta à nota pelo tique novo e pela corda; quando não dá, o app diz por quê.
  function retimeSelected(note, target) {
    const span = edit.span(note);
    if (!span) return;
    const [start, end] = target(span);
    rewriteSelected(note, start, () => edit.retime(alphaTab, note, start, end));
  }

  // Cola o recorte (do app) a partir da nota escolhida (o começo dela) ou do cursor de inserção, por cima do que
  // estava; as notas coladas ficam escolhidas.
  function pasteAt(clip) {
    let staff = null;
    let start = null;
    if (state.caret) {
      const beat = edit.resolveBeat(state.score, state.caret);
      if (beat) {
        staff = beat.voice.bar.staff;
        start = beat.absolutePlaybackStart;
      }
    } else {
      const note = selectedNote();
      const span = note && edit.span(note);
      if (span) {
        staff = note.beat.voice.bar.staff;
        start = span.start;
      }
    }
    if (!staff || !clip || !Array.isArray(clip.events)) {
      post({ type: "notice", text: "Escolha onde colar: uma nota ou uma linha vazia da TAB." });
      return;
    }
    const track = staff.track.index;
    const strings = staff.tuning.length;
    const wheres = [];
    for (const item of clip.events) {
      for (const n of item.notes) {
        if (n.string >= 1 && n.string <= strings) {
          wheres.push({ track, tick: start + Math.round(item.offset), string: strings - n.string + 1 });
        }
      }
    }
    let reason = null;
    change(() => {
      const result = edit.paste(alphaTab, staff, start, clip);
      if (result !== true) reason = result;
      return result === true;
    });
    if (reason) {
      post({ type: "notice", text: RETIME_REASONS[reason] || "Não deu para colar aqui." });
      drawSelection();
      postSelection();
      return;
    }
    chooseWheres(wheres);
    drawSelection();
    postSelection();
    post({ type: "notice", text: `Colado: ${clip.events.length} ${clip.events.length === 1 ? "batida" : "batidas"} · ⌘Z desfaz` });
  }

  // Com o cursor de inserção: a casa digitada põe a nota (e a escolhe); ↑↓ andam de corda e ←→ de batida (numa corda
  // com nota, a nota fica escolhida).
  function caretEdit(op, value) {
    const beat = edit.resolveBeat(state.score, state.caret);
    if (!beat) {
      choose(null);
      drawSelection();
      postSelection();
      return;
    }
    const string = state.caret[5];
    const count = beat.voice.bar.staff.tuning.length;
    const land = (target, alpha) => {
      const there = target.notes.find((n) => n.string === alpha);
      if (there) {
        choose(edit.pathOf(there));
      } else {
        state.caret = edit.caretOf(target, alpha);
      }
      drawSelection();
      postSelection();
    };
    const tick = state.caret.length > 6 ? state.caret[6] : null;
    switch (op) {
      case "fret": {
        if (tick !== null) {
          // No meio de uma nota longa ou de uma pausa: a nota nova entra no tique (a longa se divide).
          const staff = beat.voice.bar.staff;
          const where = { track: staff.track.index, tick, string: count - string + 1 };
          let reason = null;
          change(() => {
            const result = edit.insertAt(alphaTab, staff, tick, string, value, state.caret[7] || 0);
            if (result !== true) reason = result;
            return result === true;
          });
          if (reason) {
            post({ type: "notice", text: reason === "fret" ? "Essa casa não cabe nessa corda."
              : RETIME_REASONS[reason] || "Não deu para pôr a nota aqui." });
          } else {
            chooseWheres([where]);
            const added = selectedNote();
            if (added) hear(added, true);
          }
          drawSelection();
          postSelection();
          return;
        }
        let path = null;
        change(() => {
          const added = edit.insertNote(alphaTab, beat, string, value);
          if (added) path = edit.pathOf(added);
          return Boolean(added);
        });
        if (path) {
          choose(path);
          const added = selectedNote();
          if (added) hear(added, true);
        } else {
          post({ type: "notice", text: "Essa casa não cabe nessa corda." });
        }
        drawSelection();
        postSelection();
        return;
      }
      case "string": {
        const alpha = string + Math.sign(value);
        if (alpha < 1 || alpha > count) return;
        if (tick !== null) {
          state.caret = [...edit.caretOf(beat, alpha), tick];
          drawSelection();
          postSelection();
          return;
        }
        land(beat, alpha);
        return;
      }
      case "nav": {
        // Do meio de uma nota: ← volta ao começo dela, → vai à batida seguinte.
        if (tick !== null && value < 0) {
          land(beat, string);
          return;
        }
        const beats = beat.voice.bar.staff.bars.flatMap((bar) => bar.voices[beat.voice.index] ? bar.voices[beat.voice.index].beats : []);
        const next = beats[beats.indexOf(beat) + (value > 0 ? 1 : -1)];
        if (next) land(next, string);
        return;
      }
    }
  }

  // Uma mudança no ritmo em várias notas, uma batida de cada vez (refazer um compasso muda os tiques das outras: a
  // partitura passa pelo finish entre uma e outra e cada nota é achada de novo pelo tique e pela corda). `later`: as de
  // trás primeiro (andando para depois). Se uma não dá, nenhuma muda. A escolha volta às notas em `tick + delta`, ou a
  // `after` se dado.
  function eachBeat(notes, later, delta, apply, after) {
    const wheres = wheresOf(notes);
    const beats = [];
    for (const n of notes) {
      const span = edit.span(n);
      if (!span) continue;
      const where = { track: n.beat.voice.bar.staff.track.index, tick: span.start, string: edit.tabString(n) };
      if (!beats.some((b) => b.track === where.track && Math.abs(b.tick - where.tick) < 1)) beats.push(where);
    }
    beats.sort((a, b) => (later ? b.tick - a.tick : a.tick - b.tick));
    let reason = null;
    change(() => {
      for (const where of beats) {
        let target = edit.findNote(state.score, where.track, where.tick, where.string);
        if (!target) {
          // A nota da cabeça de uma ligadura noutra corda do acorde: qualquer nota da batida serve.
          const staff = state.score.tracks[where.track].staves.find((s) => s.tuning && s.tuning.length);
          target = staff && edit.notesOf(staff).find((n) => Math.abs(n.beat.absolutePlaybackStart - where.tick) < 1);
        }
        if (!target) {
          reason = "missing";
          return false;
        }
        const result = apply(target);
        if (result !== true) {
          reason = result;
          return false;
        }
        state.score = edit.refinish(alphaTab, state.score);
      }
      return true;
    });
    if (reason) {
      post({ type: "notice", text: RETIME_REASONS[reason] || "Não deu para mudar todas as notas." });
      drawSelection();
      postSelection();
      return;
    }
    chooseWheres(after || wheres.map((w) => ({ track: w.track, tick: w.tick + delta, string: w.string })));
    drawSelection();
    postSelection();
  }

  // Dividir (/): a nota escolhida vira duas ligadas sem mudar o som, para a segunda ter articulação dela (o vibrato no
  // fim de um bend). Onde: no cursor de inserção, se ele está dentro de uma nota; senão na agulha (`needle`, o tique que
  // o app manda), se ela está dentro da nota; senão no meio. Na grade; a parte nova fica escolhida.
  function splitAt(needle) {
    let note = null;
    let tick = null;
    if (state.caret) {
      const beat = edit.resolveBeat(state.score, state.caret);
      const at = state.caret.length > 6 ? state.caret[6] : null;
      const ev = beat && at !== null && at !== undefined
        ? edit.timeline(beat.voice.bar.staff, state.caret[7] || 0).find((e) => e.start < at && at < e.end) : null;
      if (ev) {
        note = ev.beat.notes.find((n) => n.string === state.caret[5]) || ev.beat.notes[0];
        tick = at;
      }
    } else {
      note = selectedNote();
    }
    const span = note ? edit.span(note) : null;
    if (!span) {
      post({ type: "notice", text: "Escolha a nota (ou ponha o cursor dentro dela) para dividir." });
      return;
    }
    const inside = (t) => Number.isFinite(t) && t - span.start >= edit.MIN_TICKS && span.end - t >= edit.MIN_TICKS;
    if (tick === null) {
      const atNeedle = Number.isFinite(needle) ? snap(needle, state.grid) : null;
      tick = inside(atNeedle) ? atNeedle : snap((span.start + span.end) / 2, state.grid);
      if (!inside(tick)) tick = Math.round((span.start + span.end) / 2);
    }
    rewriteSelected(note, tick, () => edit.split(alphaTab, note, tick));
  }

  // Uma mudança no ritmo (o compasso refeito): o motivo vira aviso, e a nota é achada de novo pelo tique `tick` e pela
  // corda.
  function rewriteSelected(note, tick, apply) {
    const where = { track: note.beat.voice.bar.staff.track.index, string: edit.tabString(note), tick };
    let reason = null;
    change(() => {
      const result = apply();
      if (result !== true) reason = result;
      return result === true;
    });
    if (reason) {
      post({ type: "notice", text: RETIME_REASONS[reason] || "Não deu para mudar o tempo da nota." });
      return;
    }
    const found = edit.findNote(state.score, where.track, where.tick, where.string);
    choose(found ? edit.pathOf(found) : state.selected);
    drawSelection();
    postSelection();
  }

  // MARK: as barras de duração (na edição, com "Durações" ligado)
  //
  // Embaixo de cada nota da pista principal, uma barra do tamanho do som dela (com as ligaduras) na escala da Fita.
  // Arrastar o meio move a nota no tempo; as pontas mudam o começo (o fim fica) ou o fim. Tudo cai na grade
  // (`state.grid` tiques, contados do começo do compasso); com ⌥, na grade fina (1/32). A prévia mostra a figura.
  const durationLayer = document.createElement("div");
  durationLayer.id = "durations";
  sheet.appendChild(durationLayer);

  function drawDurations() {
    durationLayer.innerHTML = "";
    const api = state.api;
    const lookup = api && api.renderer.boundsLookup;
    if (!state.durations || !state.editing || state.page || !lookup || !state.score || !state.points.length) return;
    const staff = state.score.tracks[shownTracks()[0]].staves.find((s) => s.tuning && s.tuning.length);
    if (!staff) return;
    const surface = api.canvasElement.element.getBoundingClientRect();
    const page = sheet.getBoundingClientRect();
    const stretch = zoomStretch();
    for (const ev of edit.timeline(staff)) {
      const bounds = lookup.findBeat(ev.beat);
      if (!bounds || !bounds.notes || !bounds.notes.length) continue;
      const bottom = Math.max(...bounds.notes.map((n) => n.noteHeadBounds.y + n.noteHeadBounds.h));
      const a = xAtSeconds(core.tickToSeconds(state.points, ev.start));
      const b = xAtSeconds(core.tickToSeconds(state.points, ev.end));
      if (a === null || b === null) continue;
      const bar = document.createElement("div");
      bar.className = "duration" + (selectedNote() && selectedNote().beat === ev.beat ? " chosen" : "");
      bar.style.left = a / stretch + "px";
      bar.style.width = Math.max(4, (b - a) / stretch - 1) + "px";
      bar.style.top = surface.top - page.top + bottom + 2 + "px";
      bar.dataset.start = ev.start;
      bar.dataset.end = ev.end;
      bar.beat = ev.beat;
      durationLayer.appendChild(bar);
    }
  }

  // Um tique na grade, contada do começo do compasso em que ele cai.
  function snap(tick, grid) {
    const masters = state.score.masterBars;
    let master = masters[0];
    for (const m of masters) if (m.start <= tick) master = m;
    return master.start + Math.round((tick - master.start) / grid) * grid;
  }

  durationLayer.addEventListener("pointerdown", (event) => {
    const bar = event.target.closest(".duration");
    if (!bar) return;
    event.stopPropagation();
    event.preventDefault();
    const box = bar.getBoundingClientRect();
    const edge = Math.min(8, box.width / 3);
    const mode = event.clientX - box.left <= edge ? "start" : box.right - event.clientX <= edge ? "end" : "move";
    const note = bar.beat.notes[0];
    choose(edit.pathOf(note));
    drawSelection();
    postSelection();
    state.durDrag = { bar, mode, from: event.clientX, start: Number(bar.dataset.start), end: Number(bar.dataset.end),
      left: parseFloat(bar.style.left), width: parseFloat(bar.style.width), target: null };
    try {
      durationLayer.setPointerCapture(event.pointerId);
    } catch {
      // Sem captura, o arrasto vale enquanto o ponteiro fica sobre a pauta.
    }
    bar.classList.add("dragging");
  });

  durationLayer.addEventListener("pointermove", (event) => {
    const drag = state.durDrag;
    if (!drag) return;
    const grid = event.altKey ? 120 : state.grid;
    // Pixels na tela → segundos → tiques pelo mapa, a partir do ponto arrastado.
    const pxPerSecond = (state.layoutWidth / state.renderedSpan) * zoomStretch();
    const seconds = (event.clientX - drag.from) / pxPerSecond;
    const moveTick = (tick) => snap(core.secondsToTick(state.points, core.tickToSeconds(state.points, tick) + seconds), grid);
    let start = drag.start;
    let end = drag.end;
    if (drag.mode === "move") {
      start = moveTick(drag.start);
      end = start + (drag.end - drag.start);
    } else if (drag.mode === "start") {
      start = Math.min(moveTick(drag.start), drag.end - grid);
    } else {
      end = Math.max(moveTick(drag.end), drag.start + grid);
    }
    drag.target = { start, end };
    const stretch = zoomStretch();
    const a = xAtSeconds(core.tickToSeconds(state.points, start));
    const b = xAtSeconds(core.tickToSeconds(state.points, end));
    if (a !== null && b !== null) {
      drag.bar.style.left = a / stretch + "px";
      drag.bar.style.width = Math.max(4, (b - a) / stretch - 1) + "px";
    }
    drag.bar.dataset.label = edit.figureName(end - start);
  });

  function endDurationDrag() {
    const drag = state.durDrag;
    if (!drag) return;
    state.durDrag = null;
    state.suppressClick = true;
    drag.bar.classList.remove("dragging");
    const note = selectedNote();
    if (note && drag.target && (drag.target.start !== drag.start || drag.target.end !== drag.end)) {
      retimeSelected(note, () => [drag.target.start, drag.target.end]);
    } else {
      drawDurations();
    }
  }

  durationLayer.addEventListener("pointerup", endDurationDrag);
  durationLayer.addEventListener("pointercancel", endDurationDrag);

  // MARK: pegar a nota e soltar onde ela deve ir (na edição, na faixa)
  //
  // Arrastar o número de uma nota para os lados move a nota (a batida dela, com o acorde) no tempo, mantendo a duração.
  // Um contorno tracejado mostra onde ela cai, já na grade, com o compasso e o tempo; ao soltar, os compassos são
  // refeitos (edit.retime). Com ⌥, a grade fina (1/32).
  const FRACTIONS = { 120: "1/32", 160: "⅙", 240: "1/16", 320: "⅓", 360: "3/32", 480: "1/8", 600: "5/32", 640: "⅔",
    720: "3/16", 800: "⅚", 840: "7/32" };

  // "c. 24 · tempo 3 + 1/16": onde um tique cai no compasso (tempos de semínima).
  function placeName(tick) {
    const masters = state.score.masterBars;
    let master = masters[0];
    for (const m of masters) if (m.start <= tick) master = m;
    const inside = tick - master.start;
    const beat = Math.floor(inside / 960) + 1;
    const rest = Math.round(inside % 960);
    const part = rest ? " + " + (FRACTIONS[rest] || `${Math.round(rest / 30)}/32`) : "";
    return `c. ${master.index + 1} · tempo ${beat}${part}`;
  }

  function noteAt(event) {
    const api = state.api;
    const lookup = api && api.renderer.boundsLookup;
    if (!lookup) return null;
    const surface = api.canvasElement.element.getBoundingClientRect();
    const x = (event.clientX - surface.left) / zoomStretch();
    const y = event.clientY - surface.top;
    const beat = lookup.getBeatAtPos(x, y);
    const note = beat ? lookup.getNoteAtPos(beat, x, y) : null;
    if (note) return note;
    // A ligada que a TAB não mostra (como no Guitar Pro, só com vibrato ou no começo do compasso) não tem caixa nem
    // largura: o clique na linha da corda, no espaço de tempo da batida dela, a escolhe, como o cursor do Guitar Pro.
    const slot = beatInSlot(lookup, x, y);
    const string = slot ? stringAt(slot, y) : null;
    return slot ? slot.notes.find((n) => n.string === string && n.isTieDestination) || null : null;
  }

  // A batida cujo espaço de tempo (a caixa real, que vai até a seguinte) tem o ponto, na pauta em que ele cai.
  function beatInSlot(lookup, x, y) {
    for (const system of lookup.staffSystems) {
      const r = system.realBounds;
      if (y < r.y || y > r.y + r.h) continue;
      for (const master of system.bars) {
        for (const bar of master.bars) {
          const b = bar.realBounds;
          if (y < b.y || y > b.y + b.h) continue;
          const hit = bar.beats.find((beat) => x >= beat.realBounds.x && x < beat.realBounds.x + beat.realBounds.w);
          if (hit) return hit.beat;
        }
      }
    }
    return null;
  }

  sheet.addEventListener("pointerdown", (event) => {
    if (!state.editing || state.page || event.shiftKey || event.button !== 0) return;
    if (event.target.closest(".duration")) return;
    const note = noteAt(event);
    if (!note) return;
    const span = edit.span(note);
    if (!span) return;
    state.noteDrag = { path: edit.pathOf(note), span, from: event.clientX, moved: false, target: span.start };
    try {
      sheet.setPointerCapture(event.pointerId);
    } catch {
      // Sem captura, o arrasto vale enquanto o ponteiro fica sobre a pauta.
    }
  });

  sheet.addEventListener("pointermove", (event) => {
    const drag = state.noteDrag;
    if (!drag) return;
    if (!drag.moved && Math.abs(event.clientX - drag.from) < 4) return;
    if (!drag.moved) {
      drag.moved = true;
      // A nota arrastada fica escolhida (o contorno dela é o ponto de partida do tracejado).
      choose(drag.path);
      drawSelection();
      postSelection();
    }
    const grid = event.altKey ? 120 : state.grid;
    const pxPerSecond = (state.layoutWidth / state.renderedSpan) * zoomStretch();
    const seconds = core.tickToSeconds(state.points, drag.span.start) + (event.clientX - drag.from) / pxPerSecond;
    drag.target = Math.max(0, snap(core.secondsToTick(state.points, seconds), grid));
    const a = xAtSeconds(core.tickToSeconds(state.points, drag.span.start));
    const b = xAtSeconds(core.tickToSeconds(state.points, drag.target));
    if (a === null || b === null || selectionBox.hidden) return;
    const stretch = zoomStretch();
    noteGhost.hidden = false;
    noteGhost.style.left = parseFloat(selectionBox.style.left) + (b - a) / stretch + "px";
    noteGhost.style.top = selectionBox.style.top;
    noteGhost.style.width = selectionBox.style.width;
    noteGhost.style.height = selectionBox.style.height;
    noteGhost.dataset.label = placeName(drag.target);
  });

  function endNoteDrag() {
    const drag = state.noteDrag;
    if (!drag) return;
    state.noteDrag = null;
    noteGhost.hidden = true;
    if (!drag.moved) return;
    state.suppressClick = true;
    const note = edit.resolve(state.score, drag.path);
    if (note && drag.target !== drag.span.start) {
      retimeSelected(note, (span) => [drag.target, drag.target + (span.end - span.start)]);
    }
  }

  sheet.addEventListener("pointerup", endNoteDrag);
  sheet.addEventListener("pointercancel", endNoteDrag);

  window.tracklab = {
    load(payload) {
      try {
        state.score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(decode(payload.gp), new alphaTab.Settings());
        core.showPreferences(state.score);
      } catch (error) {
        state.score = null;
        show("Não consegui ler a partitura desta música.");
        report(error);
        return;
      }
      show("");
      state.before = null;
      choose(null);
      state.undo = [];
      state.redo = [];
      state.track = Number.isInteger(payload.track) ? payload.track : 0;
      state.others = Array.isArray(payload.others) ? payload.others.filter(Number.isInteger) : [];
      setPage(Boolean(payload.page));
      state.points = core.cleanPoints(payload.points);
      post({
        type: "loaded",
        ...barInfo(),
        tracks: state.score.tracks.map((track, index) => ({
          index,
          name: track.name || "Faixa " + (index + 1),
          percussion: track.staves.some((staff) => staff.isPercussion),
        })),
        // As notas de cada pista, para as barras sobre o espectro da Fita.
        notes: core.trackNotes(state.score),
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
    page(value) {
      if (Boolean(value) === state.page) {
        return;
      }
      setPage(Boolean(value));
      if (state.score) {
        render();
      }
    },
    others(list) {
      const value = Array.isArray(list) ? list.filter(Number.isInteger) : [];
      if (JSON.stringify(value) === JSON.stringify(state.others)) {
        return;
      }
      state.others = value;
      if (state.score) {
        state.before = null;
        render();
      }
    },
    tempo(points) {
      state.points = core.cleanPoints(points);
      drawLoop();
      draw(true);
      relayout();
    },
    clock(seconds, playing, rate, delay) {
      state.clock = core.nextClock(state.clock, { seconds, playing, rate, delay }, performance.now(), CLOCK_TOLERANCE,
        state.loop);
      draw(!playing);
    },
    span(seconds) {
      if (!Number.isFinite(seconds) || seconds <= 0 || seconds === state.span) {
        return;
      }
      state.span = seconds;
      // Em páginas a escala da Fita não vale: nada a redesenhar.
      if (state.page) return;
      // Na hora: a camada na tela estica para a escala nova (acompanha a Fita); o desenho novo vem quando o zoom para.
      drawLoop();
      draw(true);
      relayout();
    },
    loop(start, end) {
      state.loop = Number.isFinite(start) && Number.isFinite(end) && end > start ? [start, end] : null;
      drawLoop();
      draw(true);
    },
    theme(name) {
      if (!THEMES[name] || name === state.theme) {
        return;
      }
      state.theme = name;
      document.documentElement.dataset.theme = name;
      render();
    },
    adjusting(value) {
      state.adjusting = Boolean(value);
    },
    // A janela da Fita: onde o cursor fica na largura (fração) e onde a pauta para sobre o loop (segundos, ou null).
    view(at, pin, hold) {
      if (Number.isFinite(at)) state.cursorAt = Math.min(1, Math.max(0, at));
      state.pin = Number.isFinite(pin) ? pin : null;
      state.hold = Number.isFinite(hold) ? hold : null;
      draw(true);
    },
    editing(value) {
      state.editing = Boolean(value);
      sheet.classList.toggle("editing", state.editing);
      if (!state.editing) {
        choose(null);
      }
      drawSelection();
      drawDurations();
      postSelection();
    },
    durations(value) {
      state.durations = Boolean(value);
      drawDurations();
    },
    grid(ticks) {
      if (Number.isFinite(ticks) && ticks > 0) state.grid = ticks;
    },
    edit(op, value) {
      try {
        runEdit(op, value);
      } catch (error) {
        report(error);
      }
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
