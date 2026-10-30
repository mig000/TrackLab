# TrackLab

Estúdio de estudo de guitarra para o Mac do Miguel (fala português do Brasil). Proposta de design (28/10/2026):
https://claude.ai/artifact/EomP8enfZv8mW3S46N5ycf.

## Decisões (28/10/2026)
- Roda primeiro no iMac 5K 2019 (i5-9600K, Radeon Pro 580X, macOS 15.8), depois no Apple Silicon: app SwiftUI
  com alvo macOS 15, sem MLX.
- O mapa de tempo inicial são os pontos de sincronização do Songsterr; daí em diante só o ajuste manual (as
  ferramentas do TabLab) mexe nele. Sem alinhamento automático da TAB.
- Separação no Intel: Demucs 6s na GPU (MPS) sempre (~1 min por música, sem internet); a guitarra boa vem do
  MVSEP pela API (o Miguel tem 10 conversões por dia; MVSep Guitar, e o 101 para solo e base); o BS-RoFormer SW
  local só como reserva na CPU (~57 min por música). Medido na Fase 0: os RoFormers não rodam na Radeon (o
  Mel-RoFormer dá resultado errado no MPS, o SW morre), o Demucs 6s dá o mesmo resultado na GPU e na CPU.
- A Fita (guitarra em âmbar sobre a silhueta da banda) é a visão padrão da onda; o Espectro fica no Ajuste.
- Gravação de takes, Helix e AU entram (Fase 5).

## Motor (`engine/`)
Python 3.11–3.12 via uv. `uv sync --extra separate --group dev`, `uv run pytest`.
- `package.py`: o pacote `<artista-título>.tracklab` (manifest.json esquema 1, score/original.gp,
  score/tempo-map.json, audio/source.flac, stems/<chave>/, peaks/). Um pacote nasce numa pasta oculta e só ganha o
  nome quando está inteiro; cada separação idem dentro de `stems/`. `save_tempo_map` grava o mapa ajustado e guarda
  o anterior em `score/tempo-map-history/` (as últimas 200 versões); antes do primeiro ajuste, copia o do Songsterr
  para `score/tempo-map-original.json` (o "Recomeçar do Songsterr" do Ajuste). Os compassos conferidos ficam no
  manifesto (`checkedBars`, `PUT songs/{id}/checked`).
- `tempomap.py`: o contrato do mapa de batida do TabLab (tiques a 960 por semínima, pontos anchor / detected /
  interpolated, âncoras com alcance de 8 batidas), copiado do backend do TabLab (`integracao`), mais
  `from_bar_starts` (os pontos do Songsterr: início de cada compasso vira `detected`, as batidas de dentro
  `interpolated`), `tap_beats` (Bater junto: um toque por batida a partir da mais perto do primeiro; as pontas viram
  âncoras, as de dentro ficam nos toques) e `halve_beats` / `double_beats` (Metade e Dobro: a densidade das batidas,
  sem mudar o tempo; âncoras e pontos ouvidos ficam).
- `repertoire.py` (Fase 3): no manifesto, `status` (want / learning / polishing / repertoire / archived) e `sections`
  (nome, from e to em tiques, meta e recorde em %, última vez, histórico); `PUT songs/{id}/status`,
  `PUT songs/{id}/sections` (o treino de cada trecho continua pelo id) e `POST songs/{id}/sections/{sid}/practice`.
  O resumo de `GET songs` traz estado, trechos, afinação da guitarra, compassos e conferidos. Fase 3b: cada trecho
  tem `kind` (trecho, lick, solo, riff, base, intro, final), `tags`, `favorite` e `bars` (quantos compassos, contados
  pelo app, que conhece as barras); no resumo, cada trecho leva também `start`, `seconds` e `bpm` pelo mapa de tempo.
- `multitracks.py`: o índice da biblioteca de multitracks (`TRACKLAB_MULTITRACKS`, `~/TrackLab/config.json` →
  `multitracks`, ou `/Volumes/HD Externo WD/Multitracks`): pastas com song.ini (Clone Hero / Rock Band), arquivos
  .mogg e pastas de faixas soltas, cada faixa com o instrumento pelo nome do arquivo; SQLite com FTS5 (sem acento,
  pelo começo das palavras) em `~/TrackLab/multitracks.sqlite`, refeito inteiro por `POST multitracks/scan` (na
  fila: ~6 min no HD frio, ~40 s com cache; 4.459 músicas em 28/10). A busca do Songsterr marca o resultado que está
  na biblioteca (mesmo título e artista, sem acento nem parênteses).
- Escada de separação (Fase 4, `stems.py`): cada fonte é uma pasta em `stems/` e só vira a ativa sem A/B se não
  houver outra (`PUT songs/{id}/stems/active`). `media/align.py` acha a multitrack sobre o áudio do vídeo (GCC-PHAT
  em 24 trechos, consenso numa reta: deslocamento e velocidade até 2 %, depois uma passada fina; ganho pela energia);
  sem consenso é outra gravação e nada entra. Medido em 28/10: Highway Star +0,39 %, Purple Haze −0,83 %, American
  Woman 72,8 s de introdução a mais no vídeo; o cover do GH3 da Sunshine é recusado. Entre transferências sobra uma
  oscilação de poucos ms (inaudível: as faixas tocam no lugar do vídeo). `media/multitrack.py` monta as faixas
  (`rhythm` do Clone Hero é a base se o song.ini tem `diff_rhythm`, senão o baixo; crowd fica fora; .mogg ainda não
  entra); `POST songs/{id}/stems/multitrack`. `media/mvsep.py` (do `mvsep_worker.py` do BackingLab 2): 63 (BS Roformer SW,
  as seis faixas numa conversão, sem Demucs), 31 (MVSep Guitar, o mesmo SW só na guitarra) e 101 (solo e base), WAV 16
  bits, sem reenvio automático; no 31 e no 101 o resto da banda é o Demucs local sobre original − guitarras (no 31 a
  guitarra leva o que o Demucs achou de guitarra no resto). A chave vem do app no
  cabeçalho `X-MVSEP-Key` de `POST songs/{id}/stems/mvsep`; a cota do dia fica em `~/TrackLab/mvsep.json`
  (`GET mvsep`). Nunca separa duas vezes a mesma música com o mesmo modelo.
- TAB sintetizada (`media/synth.py`, `stems.synthesize_tab`, `POST songs/{id}/synth`): o MIDI sai do alphaTab do
  projeto (uma trilha por pista, com as articulações) e o andamento do GP é trocado pelo do mapa de tempo (um evento
  de andamento por ponto). Sem FluidSynth (o Homebrew não o instala mais no Intel: sem pacotes, e a compilação baixa do
  GitHub dentro da caixa de areia), quem toca é o TinySoundFont do próprio alphaTab em node (`web/tools/gp-synth.cjs`,
  as sete pistas de White Room em ~6 s), com um reverb de convolução leve no motor; com o FluidSynth instalado, ele
  (`web/tools/gp-midi.cjs` + mido). O SoundFont é o de `TRACKLAB_SOUNDFONT`, `config.json` → `soundfont`, ou o
  primeiro de `~/TrackLab/Sons` (lá está o GeneralUser GS 1.471; os testes usam o Sonivox do alphaTab, Apache 2.0). Cada pista vira `synth/<chave>/t<pista>.flac` no tamanho do áudio do vídeo, a partir de onde o tique 0 cai;
  um ganho só leva todas juntas a 80 % do volume do vídeo. A chave junta GP, mapa, SoundFont e versão; o `GET songs/{id}`
  marca `synth.stale` quando o mapa mudou depois (o app oferece atualizar).
- Espectro (`media/spectrum.py`, `GET songs/{id}/spectrum?stem=guitar`): a receita da Lente do TabLab (mono 22 050 Hz,
  Hann, hop 256, FFT 4096 abaixo do Dó central e 2048 acima, linhas de 1/3 de semitom do MIDI 28 ao 96, −90 a 0 dB num
  byte) em numpy, guardada em `peaks/spectrum-*.u8` (5 min de guitarra: 2,7 s, 5 MB). As medidas vão nos cabeçalhos.
- Altura do som (`media/pitch.py`, `POST songs/{id}/pitch` com as notas da tela): a curva a cada 8 ms em cada nota,
  na guitarra da separação ativa, pela receita da Lente do TabLab (`trackPitch`: correlação normalizada em volta da
  altura escrita, de −2 a +4 semitons; `trackHarmonics` quando outra corda soa junto; mediana de 5). Conferido contra o
  `lens-core.js` original no mesmo sinal (mesmo resultado); 30 notas reais em 0,24 s.
- Partitura editada (`PUT songs/{id}/score`, o Guitar Pro 7 no corpo): `score/edited.gp`, as anteriores em
  `score/history/` (100); o manifesto aponta para a editada e guarda `original`. A TAB sintetizada guarda o SHA da
  partitura e fica `stale` quando ela muda.
- `songsterr/`: busca e importação; `vendor/` é o conversor de teaqu (MIT) que o BackingLab 2 usa, `score.py` as
  correções do BackingLab no GP. O áudio vem do vídeo principal vinculado (yt-dlp, sem cookies; node como runtime JS
  se o YouTube pedir) e é convertido uma vez para FLAC; o GP não leva áudio embutido.
- `media/`: probe / convert / peaks / separate copiados do TabLab. `separate` (Demucs 6s) cai para a CPU se o MPS
  recusar uma operação e registra o motivo no recibo.
- `models.py`: pesos baixados de uma revisão fixa e conferidos por SHA-256 (`~/TrackLab/Modelos`).
- `jobs.py` (do TabLab: um worker, eventos em disco e por SSE), `api.py` (FastAPI; o Ajuste usa
  `POST songs/{id}/tempo-map/edit` com um gesto de `anchor_edit` e `PUT songs/{id}/tempo-map` para o Desfazer),
  `cli.py` (`tracklab serve --port 0 --parent-pid N` imprime `TRACKLAB_PORT=<n>`; o motor é do app e sai com ele).
- O lock universal fixa torch 2.2.2 / numpy 1.26 (o demucs 4.1.0 exige isso no macOS x86_64); separar por
  plataforma na fase do Apple Silicon.

## Partitura (`web/`)
`score.html` + `score.js` desenham o GP do pacote com o alphaTab (horizontal; a pista escolhida e, se pedida, uma
segunda embaixo nos mesmos compassos; perfil Default com TAB nas pistas de cordas e partitura na bateria, porque o
perfil "só TAB" quebrava na bateria, que não tem TAB) e não têm áudio: o app empurra o relógio e o mapa de tempo. A TAB tem a escala da Fita (`span` segundos na largura): cada
compasso ganha `displayWidth` = duração × px/s (descontada a clave e a fórmula, medidas num primeiro desenho de cada
pista), as barras caem sobre as da Fita e a pauta corre sob o cursor parado a 40 %, na velocidade da Fita. O
alphaTab de `vendor/` tem dois ajustes marcados `TrackLab:` (notas espaçadas pela duração; o número do compasso não
ocupa largura). O relógio leva o atraso da saída de áudio (`delay`, ~0,15 s no iMac): a página só anda quando o som
sai. Antes do primeiro ponto do mapa e depois do último, a pauta anda em segundos na escala da Fita. A página dá a volta
no loop sozinha, como o `PlaybackPlan` (antes passava do fim do loop até o próximo aviso do relógio, que vem a cada
segundo), e um loop que cabe na tela (`windowStart`, a mesma conta do `LoopView` da Fita) para a pauta e solta o cursor:
até 60 % da largura o loop começa nos 40 %, maior fica centrado. As contas puras
ficam em `score-core.js`; `node web/tests/check-score.cjs` as confere e desenha os GPs de
`tests/fixtures` (feitos pelo conversor do motor) no alphaTab do node: os tiques batem com os do mapa, e barras e notas
caem no tempo.
O conversor não escreve repetições, então os pontos do Songsterr são um por compasso escrito.

Com mais de uma pauta (a segunda pista), o layout horizontal do alphaTab usa a largura do `masterBar`, não a de cada
pauta: a página dá a largura aos dois (sem isso os compassos saíam quase o dobro e a TAB descolava da Fita longe do
cursor); o que vem antes das batidas é medido só na pista principal (uma pausa de compasso na segunda fica no meio).
Cada desenho do alphaTab vai para uma camada nova, transparente, e só troca com a da tela quando termina (a pauta não
some num zoom ou num mapa novo). Com o zoom mudando, a camada da tela é esticada na hora (`renderedSpan / span`, pelo
transform da `#sheet`) e a TAB acompanha a Fita até o desenho novo chegar. A página manda as notas de cada pista
(`trackNotes`: tique, duração, altura, corda, casa) para as barras sobre o espectro da Fita.

Edição da TAB (`score-edit.js`, testado em `web/tests/check-edit.cjs`): como a do TabLab, mas sobre o próprio Guitar
Pro (o TabLab refazia a partitura de uma lista de notas em segundos e perdia detalhe na volta ao .gp). Com
`editing(true)`, um clique escolhe a nota pelas caixas do alphaTab (`includeNoteBounds`); `edit(op, valor)` muda casa,
corda (mesma altura), meio tom, apaga, navega, liga e desliga as articulações do TabLab (`toggle`: ligados, slides,
bends de tipo explícito com até 4 pontos, porque o GP7 perde um "Custom" de 5; vibratos, P.M., nota morta, let ring,
acentos, harmônicos, palhetada, tapping; no mesmo grupo ligar troca). Depois de cada mudança a partitura passa pelo
JSON do alphaTab (o `finish` liga ligados e slides à nota seguinte); a mesma cópia é o passo do Desfazer. 1,5 s depois
da última mudança, a página manda o Guitar Pro 7 (`Gp7Exporter`) e as notas novas.

## App (`mac/`)
SwiftPM sem Xcode (`./build.sh` → build/TrackLab.app, `./test.sh`), alvo macOS 15, Swift 6 em modo 5. Estado das
views por `@Local` (= SwiftUI.State). `Backend` inicia `engine/.venv/bin/tracklab serve --port 0 --parent-pid`,
lê a porta do stdout (`TRACKLAB_URL` aponta para outro motor). `StemEngine`: o original e as seis faixas num
AVAudioEngine, início comum em tempo de host, um TimePitch (velocidade 0,5–1,5, tom ±6); o loop é agendado no
player (`PlaybackPlan`: até o fim do loop e o loop de novo, 20 min por vez), sem seek a cada volta. `SongModel`
abre a música (manifesto, mapa, ondas, áudio, GP); a mixagem abre em "Sem guitarra". `FitaView`: a onda do
original e a da guitarra sob a agulha a 40 %; clique = seek, arrasto = loop preso nas batidas; o relógio é lido
direto na TimelineView (dentro de um GeometryReader a Fita não se redesenhava tocando). A partitura ganha só a altura
da pauta desenhada (`rendered.height`) e o resto vai para a Fita; o loop na TAB vai de barra a barra. Ajuste (⌘J,
Fase 2): arrastar uma batida na Fita a leva até onde ela soa (vira âncora no motor; as vizinhas acompanham até 8
batidas ou até a próxima âncora), duplo clique prende ou solta, U leva o 1 mais perto até o toque, T bate junto
(um toque por batida tocando; o trecho é regravado quando os toques param ou o loop volta), ⇧ + arrastar na TAB
desliza só a onda da Fita sob as linhas, a TAB e a grade paradas; ao soltar, a batida mais perto do cursor anda o
mesmo deslocamento (o som que ficou sob a linha é o daquela posição da TAB); Metade e Dobro; Conferido marca os
compassos do loop (ou o que toca), com faixa verde na Fita; ⌘Z / ⇧⌘Z pelo menu Editar (sem ajuste a desfazer, vão
para a cadeia de respondedores). Dois dedos ou a roda do mouse sobre a TAB ou a Fita andam pela música na escala da
tela e pausam (`ScrollCatcher`: um monitor local de rolagem, sem pegar cliques). TrackLabCore (modelos, `TempoGrid`,
`mixGains`, `MixPreset`, `PlaybackPlan`, e o estudo em `Study.swift`: estados, afinações com nome, `SpeedTrainer` e
`TodayPlan`, `LoopView`) tem os testes. O zoom (o controle deslizante do transporte, em escala logarítmica, e a pinça no
trackpad sobre a TAB ou a Fita, pelo `ScrollCatcher`) muda a Fita e a TAB juntas; os avisos de escala para a página
são um por vez, como os do relógio. A Fita mostra a onda ou o espectro da guitarra separada, como a Lente do TabLab
(`SpectrumPalette`: as cores dela, gama 1,35, o topo da escala pelo trecho, ±2 s, e a base 150 passos abaixo; 2 pixels
por linha, interpolados), com o teclado à esquerda, a janela de alturas das notas do trecho (das duas pistas, ao menos
18 semitons, deslizando tocando: `PitchWindow`), as linhas de compasso e batida por cima e as notas da pista em âmbar e
da segunda em azul como faixas que seguem a escrita (o bend sobe pelos pontos, o vibrato ondula; `ScoreNote.shape`),
com a casa e, pontilhada dentro, a altura que o som tem (as curvas chegam do motor aos poucos, pelas notas que aparecem).
Em cima do espectro, uma faixa estreita com a onda. Desenho na GPU (medido no iMac: de 4 para 60 quadros/s no espectro):
a imagem fica em ladrilhos de CALayer enviados à placa uma vez (`SpectrumLayerView`; a cada quadro só muda a
transformação) e o Canvas por cima, transparente e com `drawingGroup`, junta faixas, pontos, grade e teclado em poucos
caminhos. `TempoGrid` guarda tiques, batidas e compassos (o `seconds(at:)` por nota montava a lista do mapa a cada
pergunta). O relógio do transporte é uma NSView (`ClockLabel`): um Text que muda a cada segundo fazia a janela refazer as
restrições (~40 ms, dois quadros perdidos por segundo). Z amplia a altura em volta da nota que toca (8 semitons); ⌥⌘M
(Visualizar) esconde o mixer e a Fita ganha a altura. Editar TAB (⌘E,
`TabEditBar`): a paleta de articulações embaixo da partitura e as teclas do TabLab (0–9 casa, ↑↓ corda, ⌥↑↓ meio tom,
←→ nota, ⌫ apaga, H S B V M X N G A R P), num monitor de teclado que só vale na edição; ⌘Z desfaz a TAB na edição e o
mapa fora dela. A TAB sintetizada é feita em segundo plano ao abrir a música (e refeita ao sair do Ajuste ou da edição,
se o mapa ou a partitura mudaram); as chaves Áudio e TAB do mixer ligam e calam cada grupo inteiro, X troca um pelo
outro. No cabeçalho, "Com" escolhe a segunda pista da partitura. No mixer, a linha
TAB tem uma faixa por pista sintetizada (ids `tab:<pista>`, caladas ao chegar), que soa por cima do original ou das
faixas; um solo vale para tudo (cala o original também). A WKWebView da partitura (`ScoreWebView`) não aceita o foco
do teclado: com ele, engolia espaço, setas e letras depois de um clique na TAB e os atalhos do transporte paravam; um
clique na TAB ou na Fita também tira o foco de um campo de texto (a busca). Com mais de uma separação guardada, o A/B
abre pronto para a seguinte na escada.

Repertório (Fase 3): o app abre no Para hoje (`TodayView`: trechos perto da meta, esquecidos há 3 dias, sem recorde;
revisão do repertório a cada 7; músicas novas já conferidas). A barra lateral agrupa por estado, com busca e coleções
(sincronização a conferir, afinação). Na música: o estado no cabeçalho, os trechos acima da TAB (do loop, ou das seções
do Guitar Pro), um clique liga o loop do trecho no recorde (ou 70 %); Limpo! (⏎) conta três seguidos e sobe 5 % até a
meta. A busca da barra lateral é sem acento, pelo começo das palavras (`LibrarySearch`).

Biblioteca de trechos (Fase 3b): "Trechos" na barra lateral (`SectionsView`) junta os trechos de todas as músicas
(`SectionLibrary`: busca por nome, tipo, etiquetas, música, artista e afinação; filtros por tipo, etiqueta e favorito;
ordens tocados há pouco, esquecidos, perto da meta, por música); um clique abre a música com o loop do trecho, e o menu
muda tipo, etiquetas e favorito ali mesmo. Na música, "+ Do loop" guarda o loop como trecho (clique) ou como lick,
solo, riff… (seta); o menu de cada trecho ganhou Tipo, Etiquetas… e Favorito. A cópia independente de um lick (GP do
trecho e áudio das faixas, para sobreviver à música) ficou para depois. "Fontes › Multitracks"
consulta o índice.

Escada de separação (Fase 4): no mixer, o seletor de faixas (Demucs 6s, Multitrack, MVSEP 6 faixas, MVSEP Guitar, MVSEP Solo e base) e
o A/B (B) trocam a separação no mesmo ponto, tocando, com a mesma mixagem; "Melhorar as faixas" pede a multitrack ou o
MVSEP (com a cota do dia) e a nova chega como o outro lado do A/B. A faixa `rhythm` (Base) entra no mixer e "Sem
guitarra" cala as duas. A chave do MVSEP fica nas Chaves do macOS (TrackLab › Ajustes, ⌘,); o app ad hoc pede
permissão para lê-la de novo a cada build.

## Ambiente
- A nuvem não alcança songsterr.com nem huggingface.co: a importação real e a separação se provam no iMac.
- O iMac tem uv e este checkout em `~/Claude/TrackLab` (desde 28/10); o BackingLab 2 Intel (build 43) instalado lá não
  deve ser alterado.
- A nuvem não tem Swift: o app só compila no iMac (Swift 6.2; `test.sh` usa o Xcode 26.3 de lá, porque as CLT 26
  não trazem o módulo Testing).
- Primeira prova real (28/10, iMac): Sunshine of Your Love do Songsterr em 92 s, Demucs 6s 82,5 s na GPU sem recair
  para a CPU; o app conecta, lista o repertório e o motor sai com ele.
