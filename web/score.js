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
// Do app para a página: load({gp, track, points}), track(n), second(n | null), tempo(points),
// clock(s, playing, rate, delay),
// span(segundos), adjusting(sim), loop(a, b) / loop(null), theme("light" | "dark"), zoom(escala).
// Da página para o app (webkit.messageHandlers.tracklab): ready, loaded {tracks, bars, barTicks, sections},
// rendered {bars, ms},
// seek {seconds}, shift {seconds} (quanto a onda andou no arrasto com ⇧), shiftEnd {seconds} (o total, ao soltar),
// error {message}.
(function () {
  "use strict";

  const core = window.trackCore;
  const edit = window.trackEdit;
  const selectionBox = document.getElementById("selection");
  const SAVE_MS = 1500;
  const UNDO_LIMIT = 50;
  const viewport = document.getElementById("viewport");
  const sheet = document.getElementById("sheet");
  // A camada desenhada que está na tela; um desenho novo vai para outra camada, escondida, e só troca quando termina
  // (sem a pauta sumir no meio de um zoom ou de uma mudança de mapa).
  let tabElement = document.getElementById("tab");
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
    // A segunda pista, desenhada embaixo da primeira (null: nenhuma).
    second: null,
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
    settings.display.layoutMode = alphaTab.LayoutMode.Horizontal;
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
    state.measuring = !state.before;
    tracks.forEach(sizeBars);
    next.element.style.marginLeft = lead() + "px";
    if (!again) {
      state.renderStarted = performance.now();
    }
    whenFontsLoaded(next.api, () => next.api.renderScore(state.score, tracks));
  }

  // A pista principal e, se houver, a segunda (diferente da principal).
  function shownTracks() {
    const last = state.score.tracks.length - 1;
    const track = Math.min(Math.max(0, state.track), last);
    const second = state.second;
    return Number.isInteger(second) && second >= 0 && second <= last && second !== track ? [track, second] : [track];
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
    draw(true);
    post({
      type: "rendered",
      bars: state.score ? state.score.masterBars.length : 0,
      height: Math.ceil(tabElement.scrollHeight),
      ms: Math.round(performance.now() - state.renderStarted),
    });
  }

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

  // O cursor fica nos 40 % e a pauta corre sob ele, na velocidade da Fita; com um loop que cabe na tela, a pauta fica
  // parada e só o cursor anda (core.windowStart). A pauta anda por `transform` (frações de pixel, na GPU; `scrollLeft`
  // arredonda e alterna passos de 1 e 2 px) e o cursor fica fora dela. `now`: a hora do quadro
  // (requestAnimationFrame), para os passos saírem iguais.
  function draw(force, now = performance.now()) {
    const seconds = core.estimate(state.clock, now, state.loop);
    const x = xAtSeconds(seconds);
    if (x === null) {
      cursor.hidden = true;
      return;
    }
    const playing = state.clock && state.clock.playing;
    const width = viewport.clientWidth;
    const outside = x < state.scroll || x > state.scroll + width;
    const fixed = core.windowStart(seconds, state.loop, state.span);
    if (playing || force || outside || fixed !== null) {
      const target = fixed === null ? core.scrollFor(x, width) : Math.max(0, xAtSeconds(fixed));
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
    if (state.editing) {
      pick(event);
      return;
    }
    if (!state.anchors.length || !state.points.length) {
      return;
    }
    const page = sheet.getBoundingClientRect();
    const tick = core.tickAtX(state.anchors, (event.clientX - page.left) / zoomStretch());
    post({ type: "seek", seconds: Math.max(0, core.tickToSeconds(state.points, tick)) });
  });

  // ⇧ + arrastar, no Ajuste: nada se mexe na pauta; o app desliza a onda da Fita com o mouse.
  sheet.addEventListener("pointerdown", (event) => {
    if (!state.adjusting || !event.shiftKey || !state.anchors.length) {
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
    const beat = lookup.getBeatAtPos(x, y);
    const note = beat ? lookup.getNoteAtPos(beat, x, y) : null;
    state.selected = note ? edit.pathOf(note) : null;
    drawSelection();
    postSelection();
  }

  function selectedNote() {
    return state.score ? edit.resolve(state.score, state.selected) : null;
  }

  // O destaque da nota escolhida, em coordenadas de #sheet (as do desenho; o zoom vem do transform da #sheet).
  function drawSelection() {
    const note = state.editing ? selectedNote() : null;
    const bounds = note && state.api && state.api.renderer.boundsLookup && state.api.renderer.boundsLookup.findBeat(note.beat);
    const head = bounds && bounds.notes ? bounds.notes.find((b) => b.note === note) : null;
    if (!head) {
      selectionBox.hidden = true;
      return;
    }
    const surface = state.api.canvasElement.element.getBoundingClientRect();
    const page = sheet.getBoundingClientRect();
    const stretch = zoomStretch();
    const box = head.noteHeadBounds;
    selectionBox.hidden = false;
    selectionBox.style.left = (surface.left - page.left) / stretch + box.x - 3 + "px";
    selectionBox.style.top = surface.top - page.top + box.y - 3 + "px";
    selectionBox.style.width = box.w + 6 + "px";
    selectionBox.style.height = box.h + 6 + "px";
  }

  function postSelection() {
    const note = selectedNote();
    post({
      type: "selection",
      note: note ? edit.describe(alphaTab, note) : null,
      canUndo: state.undo.length > 0,
      canRedo: state.redo.length > 0,
    });
  }

  // Uma mudança na partitura: o passo do Desfazer antes, a cópia (o finish) depois, o desenho novo, a gravação adiada.
  function change(apply) {
    const before = { score: edit.snapshot(alphaTab, state.score), selected: state.selected };
    if (!apply()) {
      return;
    }
    state.undo.push(before);
    if (state.undo.length > UNDO_LIMIT) {
      state.undo.shift();
    }
    state.redo = [];
    replace(edit.refinish(alphaTab, state.score));
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
      to.push({ score: edit.snapshot(alphaTab, state.score), selected: state.selected });
      const step = from.pop();
      state.selected = step.selected;
      replace(edit.restore(alphaTab, step.score));
      return;
    }
    if (op === "clear") {
      state.selected = null;
      drawSelection();
      postSelection();
      return;
    }
    if (op === "select") {
      // A nota que a Fita apontou (pista, tique, corda).
      const found = value ? edit.findNote(state.score, value.track, value.tick, value.string) : null;
      state.selected = found ? edit.pathOf(found) : null;
      drawSelection();
      postSelection();
      return;
    }
    const note = selectedNote();
    if (!note) {
      return;
    }
    switch (op) {
      case "nav": {
        const next = edit.neighbor(note, value > 0 ? 1 : -1);
        if (next) {
          state.selected = edit.pathOf(next);
          drawSelection();
          postSelection();
        }
        return;
      }
      case "technique":
        change(() => edit.toggle(alphaTab, note, value));
        return;
      case "fret":
        change(() => edit.setFret(note, value));
        return;
      case "string":
        // +1 sobe para a corda mais aguda: no alphaTab, a corda de número maior.
        change(() => {
          const moved = edit.moveString(note, value);
          if (moved) {
            state.selected = edit.pathOf(note);
          }
          return moved;
        });
        return;
      case "transpose":
        change(() => edit.transpose(note, value));
        return;
      case "fit":
        change(() => edit.fit(alphaTab, note, value));
        return;
      case "delete": {
        const next = edit.neighbor(note, 1) || edit.neighbor(note, -1);
        const nextPath = next ? edit.pathOf(next) : null;
        change(() => edit.remove(note));
        state.selected = nextPath;
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
      state.selected = null;
      state.undo = [];
      state.redo = [];
      state.track = Number.isInteger(payload.track) ? payload.track : 0;
      state.second = Number.isInteger(payload.second) ? payload.second : null;
      state.points = core.cleanPoints(payload.points);
      const masters = state.score.masterBars;
      const last = masters[masters.length - 1];
      post({
        type: "loaded",
        bars: masters.length,
        // Início de cada compasso em tiques, mais o fim do último: a Fita desenha os compassos por eles.
        barTicks: masters.map((m) => m.start).concat(last ? [last.start + last.calculateDuration()] : []),
        tracks: state.score.tracks.map((track, index) => ({
          index,
          name: track.name || "Faixa " + (index + 1),
          percussion: track.staves.some((staff) => staff.isPercussion),
        })),
        // As notas de cada pista, para as barras sobre o espectro da Fita.
        notes: core.trackNotes(state.score),
        // As seções marcadas no Guitar Pro (Intro, Verse 1…): o app faz trechos de estudo com elas.
        sections: masters
          .filter((m) => m.section && (m.section.text || m.section.marker))
          .map((m) => ({ tick: m.start, name: m.section.text || m.section.marker })),
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
    second(index) {
      const value = Number.isInteger(index) ? index : null;
      if (value === state.second) {
        return;
      }
      state.second = value;
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
    editing(value) {
      state.editing = Boolean(value);
      sheet.classList.toggle("editing", state.editing);
      if (!state.editing) {
        state.selected = null;
      }
      drawSelection();
      postSelection();
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
