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
  nome quando está inteiro; cada separação idem dentro de `stems/` (a pasta `.partial` de um trabalho interrompido sai no
seguinte, depois de uma hora). `save_tempo_map` grava o mapa ajustado e guarda
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
  .mogg e pastas de faixas soltas, cada faixa com o instrumento pelo nome do arquivo (`kind_of`/`kinds_of`: o nome
  exato do Clone Hero; numa pasta de faixas soltas o começo comum dos nomes, o artista e o título, não conta; misturada
  com guitarra é guitarra, para o "Sem guitarra" calar toda; fora isso, a palavra mais perto do fim, com os compostos
  inteiros: "(03 - Bass Drum)" é bateria e "Tom Petty - … (06 - Vocals)" é voz; a primeira regra que casasse fazia 25
  bumbos dos rips do Guitar Hero virarem baixo e a voz do Tom Petty bateria; a importação refaz o instrumento pelos
  nomes, então um índice velho não erra); SQLite com FTS5 (sem acento,
  pelo começo das palavras) em `~/TrackLab/multitracks.sqlite`, refeito inteiro por `POST multitracks/scan` (na
  fila: ~6 min no HD frio, ~40 s com cache; 4.459 músicas em 28/10). A busca do Songsterr marca o resultado que está
  na biblioteca (mesmo título e artista, sem acento nem parênteses).
- Escada de separação (Fase 4, `stems.py`): cada fonte é uma pasta em `stems/` e só vira a ativa sem A/B se não
  houver outra (`PUT songs/{id}/stems/active`). `media/align.py` acha a multitrack sobre o áudio do vídeo (GCC-PHAT
  em 24 trechos, consenso numa reta: deslocamento e velocidade até 2 %, depois uma passada fina; ganho pela energia);
  sem consenso é outra gravação e nada entra. Medido em 28/10: Highway Star +0,39 %, Purple Haze −0,83 %, American
  Woman 72,8 s de introdução a mais no vídeo; o cover do GH3 da Sunshine é recusado. Entre transferências sobra uma
  oscilação de poucos ms (inaudível: as faixas tocam no lugar do vídeo). `media/multitrack.py` monta as faixas
  (`rhythm` do Clone Hero é a base se o song.ini tem `diff_rhythm`, senão o baixo; crowd fica fora); `POST songs/{id}/stems/multitrack`.
  Os .mogg do Rock Band (`media/mogg.py`; 631 na biblioteca, nenhum criptografado: 368 com o cabeçalho aberto, versão
  10, e 263 Ogg comum) vêm sem o `songs.dta`: cada canal é reconhecido pelas faixas do Demucs da música (bandas de
  energia a cada 0,1 s, correlação), depois de a soma ser alinhada ao vídeo; com 9 canais ou mais (58 de 60 numa
  amostra) a ordem do Rock Band desempata (bateria, baixo, guitarra, voz, o backing em "other"; programação dinâmica),
  porque o Demucs chamava o órgão do Highway Star de guitarra; até 8 canais o ffmpeg reordena o Vorbis e vale só a
  semelhança. Pares estéreo pela correlação. Precisa do Demucs antes: importado de uma multitrack .mogg, a música passa
  pelo Demucs e o .mogg entra depois como a outra separação. Highway Star (13 canais): certo nos 13, 33 s pela API, no mesmo lugar do vídeo que a Clone Hero (−2,7289 s contra
  −2,7286 s); no seletor, "Multitrack .mogg" (`StemSet.label` pelo `library`). `media/mvsep.py` (do `mvsep_worker.py` do BackingLab 2): 63 (BS Roformer SW,
  as seis faixas numa conversão, sem Demucs), 31 (MVSep Guitar, o mesmo SW só na guitarra) e 101 (solo e base), WAV 16
  bits, sem reenvio automático (cancelada antes do envio, nada sai e a cota fica); no 31 e no 101 o resto da banda é o Demucs local sobre original − guitarras (no 31 a
  guitarra leva o que o Demucs achou de guitarra no resto). A chave vem do app no
  cabeçalho `X-MVSEP-Key` de `POST songs/{id}/stems/mvsep`; a cota do dia fica em `~/TrackLab/mvsep.json`
  (`GET mvsep`). Nunca separa duas vezes a mesma música com o mesmo modelo.
- TAB sintetizada (`media/synth.py`, `stems.synthesize_tab`, `POST songs/{id}/synth`): o MIDI sai do alphaTab do
  projeto (uma trilha por pista, com as articulações) e o andamento do GP é trocado pelo do mapa de tempo (um evento
  de andamento por ponto). Sem FluidSynth (o Homebrew não o instala mais no Intel: sem pacotes, e a compilação baixa do
  GitHub dentro da caixa de areia), quem toca é o TinySoundFont do próprio alphaTab em node (`web/tools/gp-synth.cjs`,
  as sete pistas de White Room em ~6 s), com um reverb de convolução leve no motor (em blocos, overlap-add: 1,8 s por pista
de 4 min, antes 3,9 s com uma FFT da pista inteira); o MIDI sai com
  `extendBendArrowsOnTiedNotes` desligado: o bend no tempo da própria nota, como o Guitar Pro toca (conferido no MIDI que
  ele exporta), e não espalhado pelas ligadas como a seta do desenho (`synth.v2`); numa nota com bend e vibrato, o bend
  até onde ele para de mudar e dali ao fim o vibrato em volta do alto (`synth.v3`: num bend que segurava até o fim,
  como o "segurar" das ligadas do solo do Sunshine, o vibrato não soava); com o FluidSynth instalado, ele
  (`web/tools/gp-midi.cjs` + mido). O SoundFont é o de `TRACKLAB_SOUNDFONT`, `config.json` → `soundfont`, ou o
  primeiro de `~/TrackLab/Sons` (lá está o GeneralUser GS 1.471; os testes usam o Sonivox do alphaTab, Apache 2.0). Cada pista vira `synth/<chave>/t<pista>.flac` no tamanho do áudio do vídeo, a partir de onde o tique 0 cai;
  um ganho só leva todas juntas a 80 % do volume do vídeo. A chave junta GP, mapa, SoundFont (o SHA-256 do conteúdo,
  `font_sha`, lembrado pelo caminho, tamanho e data) e versão; o `GET songs/{id}`
  marca `synth.stale` quando o mapa, a partitura, o SoundFont escolhido agora (`soundfontSHA256` no manifesto; uma de
  antes dele compara o nome) ou a versão (`version` no manifesto) mudou depois, ou quando falta um
  arquivo dela (o app abre a música sem ele, refaz ao abrir e oferece "Atualizar a TAB sintetizada"). A importação do
  Songsterr grava a ligada depois de um bend com um Hold no alto (62 no Highway Star, 6 no Sunshine): o mesmo som que sem
  ele (conferido no MIDI), mas o desenho mostra o pontilhado. Fica assim nas ligadas sem vibrato (o pontilhado mostra
  "sobe rápido e segura"; sem ele a seta se esticaria pela ligada); ligar o vibrato numa ligada tira o Hold dela.
- Espectro (`media/spectrum.py`, `GET songs/{id}/spectrum?stem=guitar`): a receita da Lente do TabLab (mono 22 050 Hz,
  Hann, hop 256, FFT 4096 abaixo do Dó central e 2048 acima, linhas de 1/3 de semitom do MIDI 28 ao 96, cada uma o centro
  interpolado ou as raias de dentro de ±1/6 de semitom, −90 a 0 dB num byte) em numpy, guardada em
  `peaks/spectrum-<faixa>-v<VERSION>.u8` (a v1 pegava a raia de baixo e a nota subia até um semitom na imagem) (5 min de guitarra: 2,7 s, 5 MB). As medidas vão nos cabeçalhos. Um cálculo por faixa (uma trava por arquivo, gravado
  com nome temporário único): o espectro e os sons pedidos juntos esperam o mesmo cálculo (antes, o segundo a gravar
  não achava o temporário e dava erro 500).
- Sons da faixa (`media/sounds.py`, `GET songs/{id}/sounds?stem=guitar`), para a suspeita de som sem nota escrita: os
  ataques fortes (o fluxo espectral nas linhas da FFT curta, do Dó central para cima, contra a mediana de ±0,5 s mais 2
  desvios; o ataque aparece meia janela antes e é corrigido em 24 ms) e a altura de cada um (a soma harmônica até o 5º
  harmônico, 23 a 58 ms depois, com energia na fundamental e acima das vizinhas a um semitom; um segundo som no mesmo
  ataque se forte e fora dos harmônicos), lidos no espectro da Fita já guardado: `[segundo, altura, dB, dB abaixo do
  mais forte em ±2 s]`, guardados em `peaks/sounds-*-s<VERSION>.json`. Sunshine (guitarra MVSEP): 901 ataques em 0,35 s,
  o riff certo.
- Altura do som (`media/pitch.py`, `POST songs/{id}/pitch` com as notas da tela): a curva a cada 8 ms em cada nota,
  na faixa da separação ativa onde a pista soa (`stem`; a guitarra se não vier), pela receita da Lente do TabLab (`trackPitch`: correlação normalizada em volta da
  altura escrita, de −2 a +4 semitons; `trackHarmonics` quando outra corda soa junto; mediana de 5). Conferido contra o
  `lens-core.js` original no mesmo sinal (mesmo resultado); 30 notas reais em 0,24 s.
- Partitura editada (`PUT songs/{id}/score`, o Guitar Pro 7 no corpo): `score/edited.gp`, as anteriores em
  `score/history/` (100); o manifesto aponta para a editada e guarda `original`. A TAB sintetizada guarda o SHA da
  partitura e fica `stale` quando ela muda. Só entra um Guitar Pro 7 inteiro (`score_measures`: o zip, o
  `Content/score.gpif` e o XML lido em fluxo, com ao menos um `MasterBar`), e a contagem de compassos do manifesto vem
  dele (pôr ou apagar um compasso mudava a música e não a conta; o Para hoje compara os conferidos com ela). A
  gravação roda numa thread (o XML do Highway Star tem 8,7 MB: 0,2 s). Os 114 GP dos pacotes do Miguel passam (30/10).
- `songsterr/`: busca e importação; `vendor/` é o conversor de teaqu (MIT) que o BackingLab 2 usa, `score.py` as
  correções do BackingLab no GP. O áudio vem do vídeo principal vinculado (yt-dlp, sem cookies; node como runtime JS
  se o YouTube pedir) e é convertido uma vez para FLAC; o GP não leva áudio embutido.
- `media/`: probe / convert / peaks / separate copiados do TabLab. `separate` (Demucs 6s) cai para a CPU se o MPS
  recusar uma operação e registra o motivo no recibo.
- `models.py`: pesos baixados de uma revisão fixa e conferidos por SHA-256 (`~/TrackLab/Modelos`).
- `jobs.py` (do TabLab: um worker, eventos em disco e por SSE; uma importação cancelada no meio da separação termina
  cancelada, com a música já no repertório), `api.py` (FastAPI; o Ajuste usa
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
alphaTab de `vendor/` tem ajustes marcados `TrackLab:` (notas espaçadas pela duração; o número do compasso não
ocupa largura; sem a linha "rendered by alphaTab"; a velocidade do trinado no Guitar Pro 7; e três para desenhar como o
Guitar Pro 8 a ligada depois de um bend: a seta para na ligada que tem vibrato também na última batida do compasso, o
vibrato dela sai da ponta da seta e não se repete na faixa de efeitos, `tracklabBendPaintsVibrato`, e a ligada com
vibrato aparece entre parênteses; sem vibrato ela fica escondida, como no Guitar Pro; os acentos e o staccato sobre a
TAB, `TracklabAccentEffectInfo`; "let ring" em vez de "LetRing"; sem o rótulo N.H.; e, no som, o bend segue pela
cadeia de ligadas, `bendOrigin`, também na cópia pelo JSON, e bend com vibrato na mesma nota vibra de onde o bend para
de mudar até o fim). O relógio leva o atraso da saída de áudio (`delay`, ~0,15 s no iMac): a página só anda quando o som
sai. Antes do primeiro ponto do mapa e depois do último, a pauta anda em segundos na escala da Fita. A página dá a volta
no loop sozinha, como o `PlaybackPlan` (antes passava do fim do loop até o próximo aviso do relógio, que vem a cada
segundo), e com a música num loop que cabe na tela (`windowStart`) a pauta para no pino que o app manda (`view(at, pin)`, a mesma janela da Fita). Fora dele, a pauta rola com o cursor na
fração que o app manda (`state.cursorAt`, sem piso em zero: antes da música ela desce junto com a Fita). As contas puras
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
JSON do alphaTab (o `finish` liga ligados e slides à nota seguinte); a mesma cópia é o passo do Desfazer (guardada em
`state.copy` e reaproveitada como o "antes" da mudança seguinte: o alphaTab não mexe nela ao ler). Apagar a nota de onde
sai uma ligadura faz a seguinte atacar (antes o finish a prendia à nota anterior da corda, na casa dela). As gravações vão
ao motor uma de cada vez, na ordem (`scoreSave`). Antes da cópia, as ligações entre notas (ligadura, ligado, slide) ficam de mão dupla e só entre notas da partitura (`tidyLinks`: desligar um Legato deixava a nota seguinte apontando para a origem, a leitura da cópia quebrava e nada mais desenhava nem gravava); uma mudança que falha volta inteira. 1,5 s depois
da última mudança, a página manda o Guitar Pro 7 (`Gp7Exporter`) e as notas novas; `flush()` manda já (o app pede ao
fechar a música, ao sair da edição e do app: antes, trocar de música até 1,5 s depois de uma mudança a perdia). A ponte
da página com o app (colar, recortar, pausa, o flush) tem o teste dela: `node web/tests/check-page.cjs` roda o
`score.js` numa caixa do node, sem desenhar.

## App (`mac/`)
SwiftPM sem Xcode (`./build.sh` → build/TrackLab.app, `./test.sh`), alvo macOS 15, Swift 6 em modo 5. Estado das
views por `@Local` (= SwiftUI.State). `Backend` inicia `engine/.venv/bin/tracklab serve --port 0 --parent-pid`,
lê a porta do stdout (`PortReader`, em TrackLabCore: só uma linha inteira vale; `TRACKLAB_URL` aponta para outro
motor). Fechar a música grava antes o que estava a caminho (`saveEverything`: a edição da página, a TAB, os trechos) e
a música seguinte espera (`SongModel.closing`); ao sair, o app espera essas gravações até 5 s
(`applicationShouldTerminate`). `StemEngine`: o original e as seis faixas num
AVAudioEngine, início comum em tempo de host, um TimePitch (velocidade 0,5–1,5, tom ±6 e ajuste fino de ±50 cents, propriedades calculadas: com o `@Observable`, prender o
valor no `didSet` chamava o `didSet` de novo até estourar a pilha); o metrônomo (K) é uma faixa de cliques
(`Metronome.samples`, nas batidas do mapa, o 1 mais forte) gerada no app e trocada com `setClick` quando o mapa muda;
no transporte, "Tom" abre o popover com os semitons, os cents e o Lá 440 (desconta a afinação medida da gravação); o loop é agendado no
player (`PlaybackPlan`: até o fim do loop e o loop de novo, 20 min por vez), sem seek a cada volta. `SongModel`
abre a música (manifesto, mapa, ondas, áudio, GP); a mixagem abre em "Sem guitarra". `FitaView`: a onda do
original e a da guitarra sob a agulha (a 40 % até um clique: `SongModel.playheadAt`); clique na TAB, na Onda ou na
Lente = o cabeçote vai até ali e a agulha fica no lugar do clique (a tela não salta; a TAB recebe a mesma fração por
`ScoreBridge.setCursor`; dentro de um loop parado só a agulha anda); clicar, arrastar e soltar em qualquer painel, também
na edição (fora de uma nota), = loop preso nas batidas, sem tracejado. A janela (`LoopView`, guardada no `SongModel` e
mandada à TAB) tem duas medidas: a fração da agulha e o pino, onde a tela para enquanto a música está num loop que cabe.
Elas só mudam num evento (todo seek passa por `StemEngine.onSeek`, mais o loop novo e o zoom) e são escolhidas para a
tela ficar onde estava: um clique ou um loop marcado mantêm a tela; a rolagem e as teclas levam a tela junto, com a
agulha no mesmo lugar (rolar trazendo a agulha para dentro do loop não salta). Dentro do loop o pino é a tela como
está, se o loop inteiro está nela (senão a tela corre e volta com a agulha a cada volta); fora, é onde a tela vai estar
quando a música entrar nele tocando; o relógio é lido
direto na TimelineView (dentro de um GeometryReader a Fita não se redesenhava tocando). A tela da música é em camadas: a TAB, a
Onda e a Lente (a Fita em dois modos, `FitaView(lens:strip:)`), cada camada à vista ou não pelos botões do transporte
(⌥⌘1, ⌥⌘2; `waveVisible` e `lensVisible` guardados), com divisores de arrastar (`ResizeHandle`: a altura da TAB e a da
Onda sobre a Lente, guardadas; duplo clique volta ao automático). Sem altura escolhida, a TAB ganha a da pauta desenhada
(`rendered.height`) e o resto vai para as camadas; com a Onda à vista, a Lente perde a faixa estreita da onda. A Onda desenha na escala da
música (`Peaks.loudest` do original: a parte mais alta chega na borda) com o expoente 0,7 (`Peaks.display`), para
os trechos baixos e a guitarra separada ocuparem a faixa. A
Lente medir as curvas depende de ela estar à vista; o loop na TAB vai de barra a barra. Ajuste (⌘J,
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
como na Lente (`SoundNote`, em TrackLabCore/SoundCurve.swift, porta o `fitCurve` e o `shapeAt` do `lens-core.js`): a
faixa segue o som (o vibrato e o bend copiados da curva quando ela os tem; senão, a escrita), com o traço do ataque e os
pontos laranja da altura que soa (as curvas chegam do motor aos poucos, pelas notas que aparecem; a chave leva a altura,
então uma nota editada é medida de novo). Nota de acorde (outra nota da pista na mesma batida): o app manda as outras (`others`) e o
motor mede só pelos harmônicos, entre as vizinhas (até meio semitom delas), sem os harmônicos que caem perto dos delas
(a correlação acha o período comum das cordas, uma altura entre elas). No Sunshine, a de cima e a de baixo passam a ter
80–100 % dos pontos; a do meio ainda oscila, então a faixa fica na escrita, sem trinado, e acorde não entra nas
suspeitas nem na afinação; o resumo da nota vale. Editável como na Lente: um clique numa faixa liga a edição e escolhe
a nota na TAB (`select`); arrastar para cima ou para baixo muda a altura e, ao soltar, mede o som de novo em volta da
altura nova e encaixa (⌥: só a altura); F (ou "Encaixar no som") encaixa a nota escolhida: a altura presa no traste, o
bend e o vibrato do som (`fit` na página). O Guitar Pro 7 guarda o bend como origem, meio de um valor só e destino, e
reduz um Bend aos dois da ponta: o encaixe manda `(sai, 0) → (chega, q)` ou, se volta, quatro pontos
(`CurveFit.guitarPro`). O trinado se escreve: a nota na de baixo e o trinado na de cima (`fit` com `trill`, a altura MIDI, e `trillSpeed`, a
figura de cada troca medida contra a semínima, `CurveFit.Trill.speed`). O Guitar Pro guarda a velocidade numa XProperty
da nota (688062467: a duração de cada troca a 240 por semínima, 30 é fusa; visto num arquivo feito no Guitar Pro 8) que o
alphaTab ignorava: o `vendor` agora lê e grava (ajuste `TrackLab:`); o `trackNotes` manda a altura do
trinado escrito (`ScoreNote.trill`) e um trinado escrito entre as mesmas notas não é suspeito, um que o som não faz é.
Notas suspeitas (`SoundNote.checks`, tipos em `SuspectKind`): o som discorda da escrita na altura, no bend (meio tom de
diferença; uma subida que só sai no último quarto da nota é a passagem para a seguinte) ou no trinado
(`disagreements`); a nota não soa (no corpo dela, menos de um quinto dos pontos com altura); o ataque a mais de 60 ms
do começo escrito; o vibrato não escrito (vem desligado: no Sunshine eram 22 das 75 da primeira versão); e o som sem
nota escrita (`HeardSound.unwritten`: um som forte da faixa, até 18 dB abaixo do mais forte em volta, sem nota de
nenhuma pista que comece a até 120 ms na mesma altura, com um semitom de folga ou a oitava, nem nota dessa altura
soando ali). Notas de acorde não acusam altura, bend, vibrato nem silêncio. Na coluna, Suspeitas tem o filtro por tipo
com quantas há de cada um (`suspectKinds`, guardado); Tab numa nota a escolhe, num som sem nota põe o cursor de
inserção no tique dele (na grade), na corda em que a altura cai mais perto da casa da nota escrita mais próxima, com a
casa sugerida em Pôr nota (`caretPitch` na página); a Lente contorna em vermelho as notas e os sons sem nota dos tipos
ligados. Sunshine limpo (30/10): altura 35, bend 12, trinado 5, sem nota 87, não soa 1, ataque 42, vibrato 25. A
calibração dos limites vem da TAB corrigida pelo Miguel (o original e as versões ficam no pacote). Com o espectro à
vista, o app mede as curvas da pista inteira (e da segunda) em lotes de 120, meio segundo depois da última mudança de
notas, pista ou mapa (a chave da curva leva o começo e o fim da nota em segundos; um pedido que falha solta as notas e
espera 5 s, três vezes no máximo; um espectro que falha é pedido de novo na próxima vez); a Fita contorna as suspeitas em vermelho e conta no canto. Tab / ⇧Tab (também fora da edição,
com o espectro) vão de uma a outra: escolhem a nota, levam a agulha e dizem o que o som tem; o monitor de teclas da
edição (`TabEditKeys`) fica na tela da música. Sunshine (lead): 56 de 1.657 notas, 45 com a afinação descontada.
Afinação da gravação (`RecordingTuning`): a mediana do desvio do meio das notas paradas (sem bend escrito, fora de
acorde, a menos de 0,6 semitom), com ao menos 20 notas, refeita quando a pista termina de ser medida. O app guarda as
curvas como vieram e desconta a afinação delas (pontos, faixas, F, arrastar, suspeitas) e desce o espectro o mesmo
tanto; a Fita mostra "gravação +17 cents" no canto a partir de 5 cents. Medido em 30/10: Sunshine +17, White Room +5.
Cada pista é medida na faixa onde soa (`Stem.pitchSource`, pelo nome da pista: voz, baixo, teclado, a Base se a
separação a tem, senão a guitarra; a bateria não é medida): `POST songs/{id}/pitch` leva `stem`, o motor guarda as três
últimas faixas decodificadas, a chave da curva leva a separação ativa e o espectro segue a faixa da pista escolhida (os
dois últimos ficam guardados). Na barra de edição, embaixo da nota escolhida, o que o som fez (`SoundReport`): "Soou
Dó♯ 3 +8 cents · bend ¼, não escrito", o bend em % do escrito ou "não dobrou", a largura do vibrato, o trinado. As
mensagens do espectro usam os nomes da paleta ("Sol 3", `TabSelection.name`).
O som contra o mapa: a curva de cada nota traz `attack` (`media/pitch.py`, `attack`: a maior subida de energia em 10 ms
do sinal sem graves, até 120 ms antes ou depois do começo escrito, de 6 dB para cima; nil num ligado). Na Fita, um
traço branco no ataque medido quando passa de 30 ms da escrita; no Ajuste, no alto de cada compasso, a mediana dos
ataques dele (`SoundSync.barOffsets`, ao menos 3 notas, de 25 ms para cima) e "Pelo som" (A) leva o 1 do compasso que
toca até eles. Sunshine: a primeira nota soa 93 ms antes do mapa, o compasso 12 30 ms antes, o resto a menos de 25 ms. Mover a nota no tempo, que a
Lente fazia em segundos, aqui reescreve o ritmo do Guitar Pro (`edit.retime`): a voz 1 vira uma linha do tempo
(cada batida com notas é um intervalo; uma cadeia de ligaduras, um só), o intervalo muda e os compassos afetados são
refeitos com figuras (simples, pontuadas e, se preciso, tercinas), pausas nos espaços e notas ligadas no que passa da
barra de compasso (a batida original fica no primeiro pedaço, com as articulações; os seguintes são cópias ligadas). A
anterior que passar do começo novo encurta; o fim para no começo da seguinte e não passa do fim da música ("end": a
última nota levada para depois dele sumia no compasso refeito); apojaturas recusam. Na edição, arrastar o número
de uma nota na TAB para os lados move a nota (pega e solta: um contorno tracejado mostra onde ela cai, "c. 24 · tempo
3 + 1/16"); "Durações" (D) põe uma barra embaixo de cada nota (`#durations` na página): o meio move, as pontas mudam o começo ou o fim, tudo na
grade escolhida (1/8, 1/16, 1/32, tercinas; `gridTicks` guardado; com ⌥, 1/32); ⌥← ⌥→ e o arrasto lateral da Lente
andam um passo da grade. Quando não dá, a página diz por quê (`notice`); a escolha volta à nota pelo tique novo e pela
corda.
Em cima do espectro, uma faixa estreita com a onda. Desenho na GPU (medido no iMac: de 4 para 60 quadros/s no espectro):
a imagem fica em ladrilhos de CALayer enviados à placa uma vez (`SpectrumLayerView`; a cada quadro só muda a
transformação, com o y para cima como o AppKit desenha: um `isGeometryFlipped` na camada não valia e o espectro descia
ou subia vários semitons conforme a janela de alturas) e o Canvas por cima, transparente e com `drawingGroup`, junta faixas, pontos, grade e teclado em poucos
caminhos. `TempoGrid` guarda tiques, batidas e compassos (o `seconds(at:)` por nota montava a lista do mapa a cada
pergunta). O relógio do transporte é uma NSView (`ClockLabel`): um Text que muda a cada segundo fazia a janela refazer as
restrições (~40 ms, dois quadros perdidos por segundo). Z amplia a altura em volta da nota que toca (8 semitons); o botão
Mixer na ponta do transporte (ou ⌥⌘M, Visualizar) esconde o mixer e a Fita ganha a altura; a escolha fica guardada
(`showMixer`). Com ele fechado, o transporte mostra o que ouvir (Original ou um atalho de mixagem, `CompactMix`) e o X. Editar TAB (⌘E,
`TabEditPanel`): uma coluna de 252 pontos à direita da TAB, da Onda e da Lente (elas perdem largura juntas, não altura,
e a agulha segue no mesmo x), com tudo à vista e a tecla de cada comando: a nota (onde está e a figura, pelo `describe`
da página com o `placeName`; casa e meio tom com − e +; a corda, um botão por corda com a casa em que a mesma altura cai
nela, pelos `strings` do `describe`; anterior, seguinte, apagar), a duração (a figura de 1 a 1/32, pontuada, tercina,
pela `base` do `describe`, e a pausa: `length` refaz o compasso do mesmo começo, `edit.setLength`, mais curta sobra
pausa e mais longa não passa da nota seguinte; `rest` tira a batida inteira, `edit.toRest`; teclas − = . T ⇧⌫), as
articulações em grupos, o som e o encaixe, o tempo
(barras de duração, grade, um passo para os lados), as suspeitas e, embaixo, o aviso da página, Desfazer, Refazer e
Concluir; as linhas de texto têm a altura reservada, então escolher uma nota não mexe no resto. Várias notas de uma
vez: ⇧ clique (da nota de partida até ali, `edit.rangeOf`), ⌘ clique (põe ou tira uma) e ⇧← ⇧→ (`extend`); a página
guarda `group` (os endereços) e a principal, contorna as outras (`#group-selection`) e manda à coluna quantas são, de
onde a onde e o trecho em tiques. Articulação (liga em todas se a principal não tem, `toggleAll`), casa e meio tom
(`transposeAll`), corda (`moveAll`, o trecho noutra posição do braço), apagar, pausa, figura e ⌥← ⌥→ valem para todas;
as do ritmo uma batida por vez, com o finish entre uma e outra (`eachBeat`). Se uma não dá, nenhuma muda: o `change`
volta a partitura de antes (também numa só, que um compasso refeito pela metade deixava estragada). Esc com várias deixa
só a principal; os passos do Desfazer guardam a escolha. Ouvir (o ouvido, O ou ⌥Espaço, que no Mac do Miguel é o atalho global do ChatGPT) põe o loop no trecho escolhido e
toca. Nota nova: um clique numa linha da TAB sem nota (uma corda vazia de um acorde, ou uma pausa) põe o cursor de
inserção ali (`state.caret`, o endereço da batida com a corda; a corda sai da caixa do compasso, `stringAt`, com as
linhas igualmente espaçadas); digitar a casa (ou − + e "Pôr nota" na coluna) põe a nota (`edit.insertNote`) e a escolhe;
↑↓ andam de corda e ←→ de batida (numa corda com nota, a nota fica escolhida). Na faixa o cursor cai no tempo do clique,
na grade (`placeCaret`, pelas âncoras): no meio de uma nota longa, a nota nova a divide (`edit.insertAt`: o que soava
continua ligado com o que a parte dele tinha, o vibrato e o resto do bend, menos na corda da nova, e a nova ataca ali); no meio de uma pausa, a nova vai até a próxima nota ou o
fim do compasso; o cursor guarda o tique (`caret[6]`) e é desenhado no x dele. Ouvir uma nota: o clique numa nota (na
TAB, na edição, ou numa faixa da Lente) toca o trecho dela no som gravado, só a faixa onde a pista soa
(`StemEngine.audition`: sem o loop, que tocaria o começo dele no resto de uma nota que o atravessa; a mixagem fica de lado enquanto toca, a tela fica parada, `auditionView` e o `hold` da página,
e a agulha volta ao começo; tocando, não interrompe; o
seek do clique vai antes da escolha, senão calaria a nota; um clique noutra nota enquanto uma toca encerra a primeira
parada, sem virar o estudo tocando até o fim); o botão direito numa nota da TAB (também fora da edição),
numa faixa da Lente (`RightClickCatcher`, um monitor local de `rightMouseDown`) e a nota recém-posta tocam sintetizadas (`NoteSynth`: o SoundFont da TAB sintetizada, achado como o motor acha, também com `TRACKLAB_HOME`, num AVAudioUnitSampler num motor só
dele, o programa da pista pelo manifesto, o bend e o vibrato escritos pelo pitch bend de ±12 semitons, no tom e na
velocidade do estudo). Copiar e colar (⌘C ⌘X ⌘V na edição, ou os botões da coluna): o recorte são as batidas inteiras
das notas escolhidas (o acorde, as pausas do meio), do começo da primeira ao fim da última, em valores simples
(`edit.copy`: as propriedades de número, sim e não e texto de cada batida e nota, mais os pontos de bend e de alavanca;
sem endereço nem figura); vai para a área de transferência do macOS como `local.tracklab.tab-clip` (cola noutra música e
depois de reabrir o app); com notas das duas vozes, o recorte leva as duas (`voices`, e cada batida a `voice` dela) e
Recortar só deixa pausa no que foi para ele (`copied`; antes o recorte levava a voz da primeira e a outra se perdia).
Colar (`edit.paste`) entra a partir da nota escolhida (na voz dela) ou do cursor de inserção (no tique dele e na voz
escolhida), por cima do que estava, um recorte de duas vozes cada uma na sua: o que começa no trecho sai, o que vem de antes encurta até ele (com as ligadas e o que elas têm), e os compassos
são refeitos com figuras, pausas e ligaduras; não passa do fim da música. Uma nota ligada vai com as partes como estão (`parts`: o tamanho e as
articulações de cada uma; antes, o bend se esticava pela cadeia colada e o vibrato da ligada se perdia). Recortar copia
e deixa pausa. As coladas ficam escolhidas.
Voz 2: as mudanças de ritmo (figura, pausa, arrastar, ⌥← ⌥→, colar, nota nova) valem na voz da nota (`timeline` e
`rebuildBar` levam a voz; uma voz além da 1 sem nota no compasso fica com uma batida vazia, sem pausas à vista; a
escolha volta à nota pela voz também, `findNote` com `voice`, e duas notas no mesmo tique em vozes diferentes são duas
batidas no `eachBeat`); no
cursor de inserção, Voz 1 / Voz 2 escolhe onde a nota nova entra (na 2, sempre no tique do clique, com as pausas da voz 2
em volta); a linha da nota diz "voz 2". Compassos (a seção Compasso da coluna, no compasso da nota ou do cursor):
Antes e Depois põem um compasso vazio (`edit.insertBar`, com a fórmula do vizinho, em todas as pistas), Apagar tira
(`edit.deleteBar`) e Fórmula muda a do compasso (`edit.setTimeSignature`, só dele: o que passa do fim novo sai, o que
falta vira pausa); a ligadura que chegava ao compasso de depois é desfeita. O mapa de tempo acompanha
(`core.reshapePoints`): o que vem depois anda nos tiques e fica nos mesmos segundos (no mesmo lugar do áudio); um
compasso posto reparte com o de antes o tempo dele, um apagado deixa o tempo para o de antes (o de antes encolhe ou
estica por igual desde o último ponto não interpolado), e dentro de um compasso com outra fórmula os pontos esticam. A
página manda `structure` (mapa, começos dos compassos, seções do GP e a mudança, `BarChange`) e mede de novo a clave e as
fórmulas de cada compasso (`state.before`; sem isso a TAB descolava da Fita depois de um compasso posto); o app grava o mapa (vai
para o histórico do pacote), e os trechos de estudo e os compassos conferidos andam junto. O Desfazer volta a partitura
e o mapa juntos (o passo guarda os pontos e a mudança contrária). Repetições (ritornelo, casa 1 e 2) ficaram de fora: o
TrackLab supõe cada compasso escrito tocado uma vez (os pontos do Songsterr são um por compasso escrito, e a TAB
sintetizada tocaria a repetição). Dividir (/, na Duração; `edit.split`): a nota vira duas ligadas com o mesmo som, para a
segunda ter articulação dela (o bend e depois o vibrato no alto): no cursor de inserção dentro da nota, na agulha se ela
está dentro da escolhida, ou no meio, na grade; o bend se reparte pelo tempo (`bendPart`: a primeira sobe, a segunda
segura no alto como Hold, do jeito que o Guitar Pro 7 guarda, sem o trecho parado no fim, que ele perdia esticando a
subida), a segunda continua vibrato, P.M., let ring e harmônico e leva o slide e o ligado para a seguinte. O compasso
refeito mantém as ligadas com articulação própria (`breaksOf`: no mesmo lugar da nota, reaproveitando a batida; antes
virava cópia só com casa e corda e perdia o bend segurado e o ligado, e a cópia da partitura quebrava 608 vezes ao refazer
cada nota da Highway Star). Vibrato, P.M. e let ring ligados numa ligada seguem pelas seguintes que estavam iguais. A
Lente junta a cadeia numa faixa com o bend de cada parte no tempo dela (`chainBend`) e o vibrato de qualquer parte; o F
numa nota ligada reparte o bend medido entre as partes (`fitChain`) e põe o vibrato na última se nenhuma tinha. Ligada (L, a primeira de Ligados e slides,
`edit.tie`), como no Guitar Pro: a nota passa a continuar a da batida anterior na mesma corda (a casa dela e o alto do
bend, segurado) ou deixa de continuar; com ela, duas notas (o bend na primeira, o vibrato na segunda) se escrevem sem o
Dividir. Como o Guitar Pro 8 grava (conferido nele, 30/10): o Bend tem dois pontos e chega no alto a um quarto da nota
(com um terceiro no fim, a gravação reduzia aos das pontas e a subida ia até o fim da nota); a ligada depois de um bend
fica sem bend e continua no alto (um Hold nela faz o Guitar Pro desenhar o pontilhado e o vibrato por cima dele; pôr ou
tirar o bend na primeira tira o Hold das seguintes, `freeFollowers`; o Dividir, o F e o L não gravam Hold; ligar o
vibrato numa ligada tira o Hold das ligadas com vibrato da cadeia que só seguram o alto de antes, `dropHolds`, com o
mesmo som: assim saíram os dois do c. 59 do solo do Sunshine, feitos pelo Dividir de antes); o harmônico
leva o traste (`harmonicValue`: o natural na casa, os outros 12; sem ele, o Guitar Pro o apagava). A ligada que a TAB
não mostra se escolhe com o clique na linha da corda, no espaço de tempo dela (`noteAt`/`beatInSlot`: o alphaTab só
acha a batida pela área visível, que nela tem largura zero), como o cursor do Guitar Pro; a caixa da escolha fica na
linha da corda. Como o Guitar Pro grava (conferido nele): o vibrato e o let ring ficam só na nota escolhida, o P.M.
vai também para as ligadas seguintes, e P.M. e let ring não convivem. O compasso refeito não muda o som: o bend de cada
corda da nota inteira é guardado no tempo antes (`curvesOf`) e repartido pelas partes novas (`keepBend`; antes, juntar
as ligadas numa figura maior esticava a subida), e uma batida só continua a anterior se todas as cordas dela seguem
ligadas (num acorde em que só uma segue, juntar esticava as outras: o solo da Sunshine, c. 72). Conferido refazendo cada
nota das três músicas (Sunshine 1.321, White Room 2.134, Highway Star 1.978): o mesmo som. `trackNotes` sai em ordem de
tempo também com a voz 2. Segunda referência: `web/tests/fixtures/combinacoes.gp`, 32 compassos de articulações
misturadas (ligadas em cadeia, bend que volta na ligada, pela barra, com slide, H/P, P.M., let ring, acordes,
harmônicos, trinado, voz 2, tercinas, o Dividir e o L), feitos pela edição do TrackLab e salvos pelo Guitar Pro 8; a ida
e volta pelo Guitar Pro não perde nada. A coluna
de edição usa os símbolos da paleta do Guitar Pro (`NotationIcons.swift`): as figuras, os acentos, os vibratos, a nota
morta, a fantasma, os harmônicos e a palhetada na Bravura do alphaTab (o CoreText registra o woff2 do pacote), os bends,
os slides e a ligadura desenhados como na TAB; as seis figuras numa linha, do mesmo tamanho. Referência:
`web/tests/fixtures/notacao.gp`, 24 compassos com uma combinação cada (o nome no texto da primeira batida), gerado pela
edição do TrackLab e aberto no Guitar Pro 8; no repertório, "Notação (teste)" é o mesmo arquivo com silêncio. As
ligaduras das cordas são refeitas em ordem a cada cópia (`tidyLinks`: a ligada vem da nota anterior da corda na mesma
voz e segue a casa dela). As teclas do TabLab (0–9 casa, ↑↓ corda, ⌥↑↓ meio tom,
←→ nota, ⌥←→ um passo da grade no tempo, D durações, ⌫ apaga, H S B V M X N G A R P), num monitor de teclado que só vale na edição; ⌘Z desfaz a TAB na edição e o
mapa fora dela. A TAB sintetizada é feita em segundo plano ao abrir a música (e refeita ao sair do Ajuste ou da edição,
se o mapa ou a partitura mudaram: saindo da edição, a última mudança é gravada antes de perguntar; se a partitura mudou
durante a síntese, ela é refeita uma vez); as chaves Áudio e TAB do mixer ligam e calam cada grupo inteiro, X troca um pelo
outro. No cabeçalho, "Com" marca quantas outras pistas quiser embaixo da principal (`scoreOthers`, `others([…])` na
página; a largura vem do masterBar, então todas seguem a Fita); na Lente cada uma tem a sua cor (`otherColors`) e todas
são medidas. "Página" (⌥⌘P, `scorePage` guardado) desenha a TAB em páginas (`LayoutMode.Page`): sem as larguras da
Fita, um cursor próprio que anda contínuo de nota a nota no tempo, como o da faixa (`pageBeats`, `beatIndexAt`, o
`onNotesX` de cada batida e a caixa do sistema pelo `boundsLookup`; pulando de nota em nota parecia uma batida
atrasado), a página rola até o sistema novo assim que o cursor entra nele e o clique leva a música até a batida; o ⇧-arrasto fica na faixa. O loop aparece sombreado em
cada sistema por onde passa (as batidas da pista principal dentro dele, `drawPageLoop`), e arrastar de uma batida a
outra na página marca o loop (`loop` para o app, que prende nas batidas como na Fita). Visualizar ›
Aparência: do sistema, clara (papel: a Lente com a paleta de tinta `paperStops`, as marcas escuras, o âmbar mais
escuro e o fundo da Fita creme) ou escura. Fontes › Multitracks › "Procurar a TAB" abre a busca do Songsterr com o
nome da multitrack; a música importada vem sem o Demucs e com as faixas dela (`importMultitrack(path:)`), a não ser
num .mogg. No mixer, a linha
TAB tem uma faixa por pista sintetizada (ids `tab:<pista>`, a 80 % ao chegar, com o grupo TAB desligado), que soa por cima do original ou das
faixas; um solo vale para tudo (cala o original também). Os atalhos de mixagem (`MixPreset.apply`) mexem só nas faixas
da separação e tiram os solos: antes devolviam só elas, as pistas da TAB perdiam a entrada e ficavam em volume zero (a
TAB e o X não soavam com uma separação ativa). A WKWebView da partitura (`ScoreWebView`) não aceita o foco
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
muda tipo, etiquetas e favorito ali mesmo. Os trechos mudam na tela já e vão ao motor um pedido por vez, cada um
com a lista mais nova (`sectionsSave`, também na música aberta; o id do trecho novo é do app, `StudySection.newID`):
antes, duas mudanças antes da resposta partiam da mesma lista velha e a segunda desfazia a primeira. Na música, "+ Do loop" guarda o loop como trecho (clique) ou como lick,
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
