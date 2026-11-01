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
  na biblioteca (mesmo título e artista, sem acento nem parênteses). As escondidas (uma regravação que não serve, uma
  cópia repetida) ficam numa lista à parte, pelo caminho, em `~/TrackLab/multitracks-hidden.json` (`GET` e `PUT
  multitracks/hidden`): os arquivos do HD não mudam, a varredura continua indexando-as e só a busca, a marca na busca do
  Songsterr e o casamento com a música as deixam de fora (pedida pelo caminho, uma escondida vale). Em Fontes ›
  Multitracks, "Esconder" em cada linha (também no botão direito) e "Escondidas N" ao lado da busca, com "Mostrar de
  novo". 31/10: as três entradas do Ramblin' Man (a pasta do Clone Hero e dois .mogg) são uma regravação (outra
  execução, em Lá 440, 2,6 a 4,9 % mais rápida e com a razão variando; o vídeo do Songsterr é o disco, 21 cents acima),
  o alinhamento a recusou e elas ficaram escondidas.
- Takes (Fase 5, `takes.py`, `PUT songs/{id}/takes`): a lista inteira no manifesto (`takes`: id, pista de 1 a 4,
  `start` e `length` em segundos da música, `rate` e `cents` do estudo na hora, nome, favorito, `active`, a entrada); o
  app grava o áudio direto no pacote (`takes/<id>.caf`, e o timbre dos efeitos em `takes/<id>.chain.plist`) antes de
  mandar a lista, e o motor apaga os arquivos dos takes que saíram dela, depois de um minuto (um take recém-gravado chega
  ao disco antes de entrar na lista).
- Acordes pelo som (`media/chordsound.py`, `POST songs/{id}/chords/sound` com `beats`): o Chord-CNN-LSTM (Jiang, Chen e
  Xia, ISMIR 2019; Music X Lab, MIT), a rede e o decodificador do original em `media/chordnet/` (com a licença; mudados
  só o import, o `with` e o `np.int`), os cinco pesos do commit 481f4ce7 do repositório original no `models.py`
  (`CHORDNET`, ~28 MB, conferidos por SHA-256; são os mesmos que o ChordMiniApp usa). O CQT do original (`hybrid_cqt` do
  librosa, 22 050 Hz, hop 512, 288 linhas) sobre o áudio original inteiro e a média das cinco redes dão as
  probabilidades de cada quadro (~50 s para 5 min na CPU do iMac), guardadas em `peaks/chordprobs-source-v1.npy`; o nome
  sai a cada pedido, pelo HMM do original preso às batidas que o app manda (`[segundo, tipo]`: 2 no 1 do compasso, 3 no
  meio, 4 nos outros tempos; trocar custa 10, 20 e 40, porque os 15, 45 e 100 do original engoliam os acordes curtos dos
  riffs). O librosa entra no extra `separate`, com o numba < 0.61 e o llvmlite < 0.44 no Intel (os mais novos não têm
  roda para macOS x86_64). A prova de 1/11 (BTC, BTC-PL e 2E1D do ChordMini e o Chord-CNN-LSTM, na música inteira e
  sem bateria e voz): o Chord-CNN-LSTM na música inteira foi o melhor, 88 dos 93 escritos do Ramblin' Man e 18 dos 20 do
  Sultans; sem bateria e voz não ajudou.
- Acordes (`PUT songs/{id}/chords`, `set_chord_edits`): as correções da barra de acordes do app no manifesto
  (`chordEdits`: `from` e `to` em tiques e o nome; vazio é "sem acorde"), em ordem; a leitura dos acordes é do app.
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
- Reconhecer um trecho (`media/transcribe.py`, `POST songs/{id}/transcribe` com `from`, `to` em segundos, até 20 s, e
  `low`, `high` em MIDI, sem a afinação da gravação descontada): a seleção no espectro do app. A altura a cada 8 ms só
  dentro da faixa (a correlação; onde ela não acha, os harmônicos, com a folga do acorde numa faixa de menos de 8
  semitons), cortada em notas onde o som some, onde a altura salta e fica (um salto de até 3 quadros que volta é falha
  do rastreador, e um buraco de até 8 quadros na mesma altura é emendado) e onde a mesma nota é atacada de novo (a
  energia nos três primeiros harmônicos dela volta 6 dB); dois pedaços da mesma altura com até 200 ms de buraco são a
  mesma nota se a energia não volta, e o que fica a menos de 0,2 semitom da borda da faixa é outra nota puxada para
  dentro (sem isso, o retângulo do Lá do c. 106 que encostava no Fá 4 da base partia o Lá em três). Slide: um movimento de 1,5 semitom ou mais que anda de casa em casa (metade dele em
  degraus de 0,35 semitom por quadro ou mais, com patamares de até 5 quadros e alturas no meio) e para na chegada por
  60 ms; a nota de chegada diz `slide` ("previous", ou "below"/"above" quando o som já começa deslizando). Um movimento
  liso fica na nota (bend, vibrato). Medido no Sultans of Swing: o slide do c. 105 sobe 3 semitons em 110 ms em degraus
  de 0,4 a 0,8; o bend do c. 77 sobe 1,3 semitom em 150 ms, de 0,1 a 0,2 por quadro. Cada nota: `start`, `end`, `level`
  (a altura dos primeiros 40 ms), `slide` e a `curve`. Numa faixa que pega duas cordas (o Fá 4 da base e o Lá 4 do solo
  no c. 106) o rastreador alterna entre elas: o retângulo precisa ficar em volta de uma. Editar › Reconhecer um trecho
  no espectro (⌥⌘R) faz o próximo arrasto na Lente marcar o retângulo, sem segurar ⌥ (Esc cancela).
- Partitura editada (`PUT songs/{id}/score`, o Guitar Pro 7 no corpo): `score/edited.gp`, as anteriores em
  `score/history/` (100); o manifesto aponta para a editada e guarda `original`. A TAB sintetizada guarda o SHA da
  partitura e fica `stale` quando ela muda. Só entra um Guitar Pro 7 inteiro (`score_measures`: o zip, o
  `Content/score.gpif` e o XML lido em fluxo, com ao menos um `MasterBar`), e a contagem de compassos do manifesto vem
  dele (pôr ou apagar um compasso mudava a música e não a conta; o Para hoje compara os conferidos com ela). A
  gravação roda numa thread (o XML do Highway Star tem 8,7 MB: 0,2 s). Os 114 GP dos pacotes do Miguel passam (30/10).
- `songsterr/`: busca e importação; o vídeo vinculado às vezes tem menos pontos de sincronia que compassos (o Songsterr
  para antes do fim: Something 50 de 51, Norwegian Wood 60 de 62, Penny Lane 85 de 86, A Hard Day's Night 85 de 89):
  até 4 e até 10 % dos compassos, os que faltam no fim seguem o andamento do último com ponto (`MISSING_MAX`, `_extend`,
  com aviso para conferir no Ajuste); antes o áudio ficava de fora. Uma música que entrou só com a partitura busca o áudio
  de novo (`add_audio`, `POST songs/{id}/audio`, na fila; no app, Faixas › "Buscar o áudio de novo"): a partitura fica,
  o áudio e o mapa entram. Nos quatro Beatles (1/11), contra a Isophonics, TAB e som juntos: 84, 91, 95 e 83 %; `vendor/` é o conversor de teaqu (MIT) que o BackingLab 2 usa, `score.py` as
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
pista), as barras caem sobre as da Fita e a pauta corre sob o cursor parado a 40 %, na velocidade da Fita. Tocando,
quem anda (a pauta, ou o cursor sobre a pauta parada no pino do loop) desliza numa animação do WebKit com os próximos
30 s calculados a cada 50 ms da música (`glide`), refeita quando o relógio, a escala, a janela ou o loop mudam e meio
segundo antes de acabar (a anterior sai 300 ms depois de a nova entrar por cima, `retire`: cancelada na hora, a pauta
tremia um ou dois pixels a cada troca, 1/11): a animação de transform corre no Core Animation, e o transform escrito a cada quadro passava
pela linha principal do app, ocupada com a Fita e a Lente, e a TAB perdia quadros (1/11). Mesmo assim a página
ainda engasgava quando a linha principal do app demorava (a página só desenha depois de o app aceitar o quadro
anterior): ver os rótulos e a agulha do mapa abaixo (`CanvasLabel`). Os textos das batidas ficam
em até três linhas, cada um na primeira em que cabe sem tocar o anterior na escala da Fita (`placeTexts`, a linha em
`beat.tracklabTextLine`, `TextEffectInfo(line)` no alphaTab): no começo do Sultans, "Mark plays exclusively…", no
compasso 1, que é curto, cobria o "w/ Slight reverb" do 2. O
alphaTab de `vendor/` tem ajustes marcados `TrackLab:` (notas espaçadas pela duração; o número do compasso não
ocupa largura; sem a linha "rendered by alphaTab"; a velocidade do trinado no Guitar Pro 7; e três para desenhar como o
Guitar Pro 8 a ligada depois de um bend: a seta para na ligada que tem vibrato também na última batida do compasso, o
vibrato dela sai da ponta da seta e não se repete na faixa de efeitos, `tracklabBendPaintsVibrato` (um bend que volta ao
chão antes da ligada deixa o vibrato na faixa: o c. 77 do Sultans mostrava dois), e a ligada com vibrato aparece entre
parênteses, com a volta parando em cima do número; sem vibrato ela fica escondida, como no Guitar Pro; a ligadura de
uma cadeia que começa num bend fica embaixo da nota, sem cruzar a seta (`tracklabTieUnderBend`); os acentos e o staccato sobre a
TAB, `TracklabAccentEffectInfo`; a parte da música (o marcador) e os nomes dos acordes com linha própria, como no Guitar
Pro (antes dividiam a linha com os vibratos); "let ring" em vez de "LetRing"; sem o rótulo N.H.; e, no som, o bend segue pela
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
(`trackNotes`: tique, duração, altura, corda, casa, vibrato, trinado, como a nota chega e sai e o bend; a chegada é 1
quando ela vem de outra casa pela corda, num ligado, num slide da anterior ou num slide de fora, e a saída 2 quando sai
por slide, `ScoreNote.approached`/`slidesOut`; mais 4 ou 8 quando esse slide é para fora, para cima ou para baixo, e 16
ou 32 quando ela entra por um slide de baixo ou de cima) para as barras sobre o espectro da Fita, e com elas os acordes
escritos no Guitar Pro (`writtenChords`: tique, pista e nome de cada batida com acorde) para a barra de acordes.

Edição da TAB (`score-edit.js`, testado em `web/tests/check-edit.cjs`): como a do TabLab, mas sobre o próprio Guitar
Pro (o TabLab refazia a partitura de uma lista de notas em segundos e perdia detalhe na volta ao .gp). Com
`editing(true)`, um clique escolhe a nota pelas caixas do alphaTab (`includeNoteBounds`); `edit(op, valor)` muda casa,
corda (mesma altura), meio tom, apaga, navega, liga e desliga as articulações do TabLab (`toggle`: ligados, slides,
bends de tipo explícito com até 4 pontos, porque o GP7 perde um "Custom" de 5 (`gpSafe` reduz aos quatro que pesam,
com aviso, antes de gravar; o exportador o jogava fora em silêncio); vibratos, P.M., nota morta, let ring,
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
views por `@Local` (= SwiftUI.State).

A tela da música, redesenhada em 31/10 (a proposta, com as pranchas: https://claude.ai/artifact/71SvyMjBhJgvsTxf1X71yc):
três modos num seletor no centro da barra, `SongModel.mode` (Estudar; Editar, ⌘E, = `editingTab`; Ajustar, ⌘J, =
`adjusting`), cada um com o lado direito da barra e o inspetor dele. À esquerda da barra o título com o estado (um menu).
Um inspetor só à direita (`InspectorPanel`, 300 pt, ⌥⌘I, `showInspector`), com o conteúdo pelo modo: em Estudar, o
Trecho (o ativo: recorde, meta, a sequência, Limpo!), o Mixer (Original/Faixas, os atalhos, cada faixa com M/S e volume,
a TAB sintetizada com o X e as pistas) e as Faixas (a separação, o A/B, Melhorar, a cota do MVSEP); em Editar, a nota
(`TabEditPanel`); em Ajustar, a Sincronização (`SyncInspector`: os conferidos, os compassos fora pelo som com "Ir", as
versões, Recomeçar). O mixer de baixo da tela saiu: a Lente ganhou a altura. Os grupos do inspetor abrem e fecham
(`InspectorGroup`, a escolha guardada em `group.<chave>`). Sob a barra, o mapa da música (`SongMapView`): a música inteira
numa linha, as partes (as seções do Guitar Pro, `songParts`) nas cores delas, os trechos de estudo como chaves em cima
(recorde → meta; a ativa cheia; o botão direito tem o menu do trecho), os compassos conferidos em verde embaixo, as
suspeitas em vermelho, o loop e a agulha; um clique leva a música até ali (numa chave, liga o trecho), arrastar marca o
loop; na ponta, "+ Trecho do loop" (com "um trecho por parte da música" quando não há trechos). Os chips dos trechos
saíram. O transporte só tem o que é de tocar: play, relógio, Loop (com o tempo dele no botão), metrônomo, velocidade,
Tom, Ouvir (Original e os atalhos; o X quando o mixer do inspetor não está à vista), o zoom − + e, com um trecho ativo,
o Limpo!. A Onda, a Lente e a TAB em páginas ficam no menu Visão da barra (⌥⌘1, ⌥⌘2 continuam) e no canto da TAB
(Faixa · Página, "Com:" as outras pistas; na edição, a grade e as barras de duração). A Lente tem selos no canto
(`LensBadges`): a afinação da gravação, as corrigidas, as suspeitas (o clique abre o filtro por tipo, `SuspectFilter`)
e o Z. Uma linha de estado entre as camadas e o transporte (`StatusLine`): a última ação ou aviso com "⌘Z desfaz", a
parte que toca, os conferidos e as suspeitas. ⌘/ abre a folha de teclas (`KeysSheet`); a coluna perdeu as teclas em
cada botão. O botão direito (`NoteMenu.swift`), em qualquer modo: numa nota (na TAB, pela mensagem `context` da
página com a nota descrita e o ponto, ou numa faixa da Lente) a edição liga, a nota é escolhida e o menu abre
(`contextMenu(forTrack:tick:string:)`, à espera da escolha em `pendingMenu`): a cabeça com a nota e o que soou, uma
linha com as oito articulações mais usadas e outra com a casa (− +) e as cordas como controles (NSHostingView dentro
do NSMenu), Ouvir, Encaixar, as Leituras, Bend, Mais articulações, Duração, Dividir, Mover no tempo, meio tom, Loop,
Reconhecer, recortar/copiar/colar/apagar; no número do compasso (ou fora de uma nota, na Onda e na Lente), o
compasso: loop, guardar como trecho, Conferido, sincronizar e corrigir pelo som, pôr antes e depois, fórmula, apagar
(`editBar(index:)`; a página aceita o índice em `bar` e tem o op `selectBar`), escolher as notas, reconhecer. A barra
lateral tem Coleções (uma por vez, de novo todas) e o "+ Do Songsterr" fica na barra da janela.

Gravar (31/10, Fase 5; as pranchas "Estúdio · Gravar" e "O botão direito no take" na proposta do redesenho): o quarto
modo (⌘R, `recordMode`). A entrada da guitarra (`AudioInput.swift`, `InputEngine.shared`, do app inteiro) é um
AVAudioEngine só dela, no dispositivo escolhido (no Mac a entrada e a saída do motor são um AUHAL só: um dispositivo com
saída, como o Helix, fica com as duas, um relógio só; um sem saída, como o microfone do iMac, deixava a saída sem canais e
o motor não ligava, −10875, então vira um agregado privado com a saída padrão; o que ligou, as mudanças de configuração
e o pico do sinal nos 3 primeiros segundos vão para `~/Library/Logs/TrackLab-entrada.log`; o aviso de configuração que
o próprio dispositivo escolhido dispara só religa o motor, sem remontar: remontando, o Helix religava sem parar; e o
monitor entra no mixer principal com o formato explícito: com `format: nil` a entrada inteira dava zero, já no tap do
dispositivo, em qualquer dispositivo), com os
canais pelo mapa do AUHAL só quando não são os primeiros (no Helix, 1/2 é o som processado e 7 o DI), os efeitos AU no caminho (a janela de cada um,
ligar e desligar, a ordem; a cadeia guardada entre as aberturas e com cada take), ouvir pelo Mac (desligado: o Helix já
devolve o som sem atraso), o nível e o afinador (`Tuner`, YIN, a cada 4.096 amostras); o microfone pede a permissão do
macOS (`NSMicrophoneUsageDescription` no build). A gravação escreve tudo o que entra num arquivo e marca o instante de
host do primeiro quadro menos a latência da entrada; R para (ou uma pausa, um salto, outra velocidade:
`StemEngine.transportVersion`) e `TakeCut.passes` corta pelo relógio do plano (`StemEngine.Clock`: a música ouvida em
cada instante de host): com loop, cada volta vira um take recortado no loop (o pré-rolo de um compasso fica de fora; uma
volta de menos de 1 s ou de meio loop, também), sem loop, um take; mais o ajuste à mão em ms do inspetor. Os takes
(`TakeStudio`, `Recording.swift`) ficam em pistas Guitarra 1 a 4: numa pista, entre os que se sobrepõem, só um soa
(`TakeLanes.choose`; o último gravado), B passa ao anterior (`alternate`), um clique no take o faz soar. Cada take toca
num player do `StemEngine` ("take:<id>") agendado por `TakeSchedule.pieces` (silêncio até ele, o áudio, silêncio no
resto de cada volta, contado em quadros do arquivo sem acumular arredondamento); gravado noutra velocidade ou noutro tom,
passa por um time-pitch dele (rate 1/r, o tom ao contrário) antes do barramento e sai no tempo e no tom da música. No
mixer, Takes liga e cala todos, cada pista com volume e mudo; a pista armada cala enquanto grava. A camada dos takes
(`TakesLane`, sob a TAB no Gravar) desenha cada pista: o take que soa com a onda, os outros em linhas finas, o que está
sendo gravado crescendo em vermelho; o botão direito num take: ouvir sozinho, escolher, comparar, favorito, renomear,
levar para outra pista, usar o timbre dele, loop nele, exportar (WAV 24 bits), mostrar no Finder, apagar. Na Lente, a
nota ao vivo: o rastro vermelho da altura que entra (o tom do estudo descontado) e um ponto na agulha. No Estudar, o
grupo Guitarra do inspetor liga a entrada para tocar junto sem gravar. Provado no iMac (1/11, Sultans): um loop de 2,9 s
gravado por 20 s dá 10 takes de uma volta e o último pela metade, todos no começo do loop; com o Helix 1/2 o som chega
(−21 dB tocando; parado, −57 dB de zumbido da rede, que o afinador lia como "Si 1, 60 Hz": abaixo de −48 dBFS ele não
lê). O atraso: os atrasos da saída (no relógio) e da entrada (no primeiro quadro) já saem da conta; tocando junto, o
primeiro ataque de cada volta caiu de 4 a 6 ms depois do 1 do loop, mas o resto foi tocado solto do metrônomo, então
uma calibração firme ainda falta. Cada build ad hoc pede o microfone de novo (o aviso do macOS); um teste pelo
terminal (ffmpeg, um AVAudioEngine) usa a permissão do `claude`. `Backend` inicia `engine/.venv/bin/tracklab serve --port 0 --parent-pid`,
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
os trechos baixos e a guitarra separada ocuparem a faixa. A silhueta da banda (o original) tem a cor da parte da música
(as seções do Guitar Pro, `songParts`; `SongParts` dá a família, "Verse 2" e "Verso" são a mesma, e a cor dela, sem
amarelo nem laranja, que são da guitarra), também na faixa da onda em cima da Lente, e o nome de cada parte fica embaixo,
no começo dela (a que já começou, presa na borda esquerda); cinza fora das partes e numa música sem seções. A
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
(`SpectrumPalette`: gama 1,35, o topo da escala pelo trecho, ±2 s, e a base 150 passos abaixo; 2 pixels por linha,
interpolados; desde 1/11 a Lente é sempre escura, também na aparência clara, e a paleta tem um piso: o terço de baixo
é o fundo, sem a névoa do ruído e do vazamento, e daí um azul frio que para num azul claro, sem branco, para as faixas
âmbar e os pontos da altura ficarem sempre mais vivos; as faixas cheias com um contorno fino), com o teclado à esquerda, a janela de alturas das notas do trecho (das duas pistas, ao menos
18 semitons, deslizando tocando: `PitchWindow`), as linhas de compasso e batida por cima e as notas da pista em âmbar e
da segunda em azul como faixas que seguem a escrita (o bend sobe pelos pontos, o vibrato ondula; `ScoreNote.shape`; o
slide desliza no fim da nota até a altura da seguinte da corda, ou 3 semitons para fora, e o de fora entra 3 semitons
abaixo ou acima, em até 0,15 s, `ScoreNote.slideOffset`: antes a faixa ficava reta e nenhum slide aparecia, como o
12–14 do c. 105 do Sultans),
como na Lente (`SoundNote`, em TrackLabCore/SoundCurve.swift, porta o `fitCurve` e o `shapeAt` do `lens-core.js`): a
faixa segue o som (o vibrato e o bend copiados da curva quando ela os tem; senão, a escrita), com o traço do ataque e os
pontos claros da altura que soa (laranja até 1/11, quando sumiam dentro da faixa âmbar; as curvas chegam do motor aos poucos, pelas notas que aparecem; a chave leva a altura,
então uma nota editada é medida de novo). Nota de acorde (outra nota da pista na mesma batida): o app manda as outras (`others`) e o
motor mede só pelos harmônicos, entre as vizinhas (até meio semitom delas), sem os harmônicos que caem perto dos delas
(a correlação acha o período comum das cordas, uma altura entre elas). No Sunshine, a de cima e a de baixo passam a ter
80–100 % dos pontos; a do meio ainda oscila, então a faixa fica na escrita, sem trinado, e acorde não entra nas
suspeitas nem na afinação; o resumo da nota vale. Editável como na Lente: um clique numa faixa liga a edição e escolhe
a nota na TAB (`select`); arrastar para cima ou para baixo muda a altura e, ao soltar, mede o som de novo em volta da
altura nova e encaixa (⌥: só a altura); F (ou "Encaixar no som") encaixa a nota escolhida: a altura presa no traste, o
bend e o vibrato do som (`fit` na página). O bend do som sai num tipo do editor (`CurveFit.form`, um `BendForm`), nos
pontos que o Guitar Pro 7 guarda (`CurveFit.guitarPro`). A detecção (`SoundNote.fit`, refeita em 31/10 e medida nas
três músicas, abaixo): a casa é a escrita quando o som passa perto dela (o grave dele a meio semitom, ou 40 % dos
quadros a meio semitom dela: o som que fica na nota com uma entrada curta de baixo, o fim da nota anterior ou um ligado
que o Songsterr não escreve, era "outra altura e bend"), ou quando fica entre ela e o alto do bend
escrito (`written`, os pontos do bend da nota: o rastreador perdeu o começo de um bend rápido, ou é um pré-bend; antes o
grave do começo virava a casa, e um bend rápido ou o fim dobrado da nota anterior, que o rastreador ainda ouve nos
primeiros quadros num solo de bends, punham a nota um ou dois semitons acima, "outra altura"); se o som nunca passa
pela casa e o bend escrito sai dela, o começo não é pré-bend (a subida perdida; sem isso, 30 bends escritos das músicas
viravam "pré e bend"); numa nota que chega de outra casa (`approached`), a entrada fica fora da medida até o primeiro
quadro a meio semitom da altura escrita, se ele chega nos primeiros 250 ms (ou três quartos de uma nota curta), e numa
que sai por slide sem bend escrito (`slidesOut`), o que vem depois do último quadro a um quarto de semitom dela nos
últimos 250 ms (o começo da subida até meio semitom já seria um bend de ¼); o começo que ainda é a nota anterior (o
rastreador fica nela até o ataque desta dominar: no reference.gp, 50 a 150 ms dois a quatro semitons acima, que viravam
"bend de 1 tom", "pré e bend" ou "pré e volta") fica fora: a nota começa a um semitom ou mais da altura escrita (do
pré-bend, se escrito) e cai a meio semitom dela em até 40 ms, a 30 semitons por segundo ou mais, nos primeiros 200 ms
(ou na primeira metade de uma nota curta), a não ser que comece dentro do bend escrito dela; três alturas acima da
casa dizem o tipo: o ataque (o grave dos primeiros 100 ms ou um quinto da nota; pré-bend de meio tom para cima), o alto
(com vibrato, a curva de 200 ms menos a meia oscilação; sem ele, a de 40 ms, que alcança o bend que só chega no fim da
nota, sem os primeiros 50 ms) e o fim (a curva de 40 ms no último sétimo); um salto de ¾ de semitom no último quarto da
nota (entre dois quadros com altura, seguidos ou com até 7 vazios no meio, ou com quantos forem quando cai na altura da
seguinte; ou um semitom em até 24 ms, a troca que o rastreador espalha por dois ou três quadros) já é a nota seguinte e
fica fora da medida; as alturas no semitom
inteiro mais perto, ¼ de tom até 0,85 semitom (o limite da Lente do TabLab), ¾, 1¼… só a 0,1 semitom deles, até 3 tons
(`quarterTones(rise:)`); a volta mede quando começa, quando acaba e até onde vai. Um movimento precisa deslizar na curva
crua: um salto direto entre dois quadros seguidos é degrau (ligado, pull-off, o rastreador trocando de som) e não é
bend nem volta; com quadros vazios no meio (o rastreador perde a corda que desliza depressa) o F escreve, mas o bend
fica `certain` falso e não acusa sozinho uma nota sem bend escrito. A passagem para a nota seguinte não é bend (no F
também, que antes a escrevia: o "½" do c. 1 do Sunshine): a subida que só sai no último quarto, ou depois da metade e
chega à altura da seguinte (`next`, a nota da corda que começa onde esta acaba, pelo alto da curva de 40 ms), e a volta
no último quarto que cai na altura da seguinte, noutra casa. O trinado se escreve: a nota na de baixo e o trinado na de cima (`fit` com `trill`, a altura MIDI, e `trillSpeed`, a
figura de cada troca medida contra a semínima, `CurveFit.Trill.speed`). O Guitar Pro guarda a velocidade numa XProperty
da nota (688062467: a duração de cada troca a 240 por semínima, 30 é fusa; visto num arquivo feito no Guitar Pro 8) que o
alphaTab ignorava: o `vendor` agora lê e grava (ajuste `TrackLab:`); o `trackNotes` manda a altura do
trinado escrito (`ScoreNote.trill`) e um trinado escrito entre as mesmas notas não é suspeito, um que o som não faz é.
Notas suspeitas (`SoundNote.checks`, tipos em `SuspectKind`): o som discorda da escrita na altura, no bend (meio tom de
diferença na altura mais alta; pelo tipo, com meio tom de folga: o som começa dobrado e a escrita não, `.prebend`, ou o
pré-bend escrito não soa, `.noPrebend`; o som volta e a escrita não, `.release`, ou a volta escrita não soa,
`.noRelease`; o pré-bend escrito parado soa como a nota mais alta e está certo; o tempo de chegada não acusa, porque o
Songsterr escreve toda subida "ao longo da nota") ou no trinado
(`disagreements`); a nota não soa (no corpo dela, menos de um quinto dos pontos com altura); o ataque a mais de 60 ms
do começo escrito; o vibrato não escrito (vem desligado: no Sunshine eram 22 das 75 da primeira versão; o ataque e o
som sem nota também vêm desligados desde 31/10, porque mais poluíam a lista do que ajudavam: a escolha guardada passa a
`suspectKinds2`, a de antes sem os dois); e o som sem
nota escrita (`HeardSound.unwritten`: um som forte da faixa, até 18 dB abaixo do mais forte em volta, sem nota de
nenhuma pista que comece a até 120 ms na mesma altura, com um semitom de folga ou a oitava, nem nota dessa altura
soando ali). Notas de acorde não acusam altura, bend, vibrato nem silêncio. Na coluna, Suspeitas tem o filtro por tipo
com quantas há de cada um (`suspectKinds`, guardado); Tab numa nota a escolhe, num som sem nota põe o cursor de
inserção no tique dele (na grade), na corda em que a altura cai mais perto da casa da nota escrita mais próxima, com a
casa sugerida em Pôr nota (`caretPitch` na página); a Lente contorna em vermelho as notas e os sons sem nota dos tipos
ligados. O corretor (31/10; `TrackLabCore/Reading.swift`, `Corrector.swift`, `ReadingCards.swift`): o processo invertido,
o detector decide e o Miguel confere onde tiver dúvida. "Corrigir pelo som" (⇧F na edição, Editar › Corrigir a TAB pelo
som, ⌥⌘F; o botão em Leituras) escreve, num passo só do Desfazer, a correção de cada nota fora de acorde da pista
principal (só o loop, se há um): `SoundNote.correction` parte da escrita e troca só o que o som discorda com segurança
(a altura até um semitom, com o bend e o vibrato do som; o bend pelo tipo e alturas, e o tempo de um bend escrito igual
fica; o vibrato que o som tem e a escrita não) e só se a nota chega perto do som (`closeness`, de 0 a 1: a raiz da média
dos quadrados da diferença entre a forma da leitura e a curva de 40 ms do som, ou a de 200 ms menos a meia oscilação com
vibrato, na janela que o encaixe mediu, `CurveFit.window`; um semitom de diferença média é 0; o vibrato que discorda
tira 0,1): a forma muda se ganha 15 pontos e fica em 50 % ou mais, o vibrato sozinho se fica em 75 % ou mais. O trinado
não muda sozinho (no White Room, dezenas no mesmo riff: o rastreador alternando com outra coisa); fica entre as
leituras. Sem as curvas, liga a Lente, mede e corrige quando a medida termina (com o que chegou). A página aplica o lote
(`edit("fitMany", [{track, tick, string, pitch, bend, vibrato, trill, trillSpeed}])`, o `edit.fit` de cada nota, as que
não acha ficam de fora) e responde `fitted`. As corrigidas ficam em `SongModel.corrections` (pista:tique:corda → como
estavam e como ficaram; sai a que não está mais como ficou: desfeita, mudada de novo), com contorno verde tracejado na
Lente e a contagem no canto e na coluna. Na edição, a nota escolhida mostra em Leituras até quatro cartões desenhados
(`SoundNote.readings`: a do som, a escrita, a de antes do corretor e variações: ¼ a mais ou a menos, sem a volta, sem
bend, a casa de cima, o vibrato trocado; em ordem de `closeness`, sempre com a escrita e a original): à esquerda a TAB
(a casa, a seta do bend com a altura, a volta tracejada, o vibrato, o tr), à direita a forma da leitura em âmbar sobre os
pontos do som, embaixo quão perto do som; um clique ou ⌥1–⌥4 escolhe (o `fit` da página), o alto-falante ouve
sintetizada (`playSynth`). Com várias notas, os cartões são o trecho noutras posições do braço (até três cordas acima ou
abaixo onde todas cabem, a afinação de cada corda pelas notas da pista; o "string" da página). Medida
(`TRACKLAB_CORRECTOR_BENCH=<arquivo> mac/test.sh --filter medicaoDoCorretor`, com `original` em cada nota, a TAB do
Songsterr de antes da edição): das 24 notas que o Miguel corrigiu no Sunshine (19 vibratos postos, bends do solo, uma
altura), o corretor faz 16 iguais, 3 diferentes (os bends do solo, c. 59–61) e deixa 5; muda 180 notas das 3.152 das
três músicas fora de acorde (altura 79, bend 58, vibrato 66), 32 das 685 dos licks e 13 das 198 do reference (as duas
últimas são TABs revisadas: a precisão de verdade vem do GOAT, que um agente está montando). Visto no app (Highway Star,
com backup e restauração): 21 corrigidas, as suspeitas 138 → 119; um bend rápido com o começo perdido ainda sai "pré ½
e bend" (c. 250), e o cartão "Original" o volta num clique. Sunshine limpo (30/10): altura 35, bend 12, trinado 5, sem
nota 87, não soa 1, ataque 42, vibrato 25. A
calibração dos limites vem da TAB corrigida pelo Miguel (o original e as versões ficam no pacote). Medição (`bench/`):
quatro conjuntos de notas com a curva do som de cada uma, em `~/TrackLab/Medidas` (`TRACKLAB_BENCH_DIR`): `musicas.json`
(`node web/tools/bend-curves.cjs <motor> ~/TrackLab/Medidas/musicas.json`, as guitarras do repertório pelo motor
rodando, com a TAB original do pacote em `original`), `licks.json` e `reference.json` (`zsh bench/licks/refazer.sh`,
~1 min: os Guitar Pro com áudio dentro de "Blues Licks" no HD externo, os ajustes de sincronia em
`bench/licks/ajustes.json`, achados por `bench/licks/sincronia.py`) e `goat.json` (`zsh bench/goat/refazer.sh <pasta
GOAT>`, ~15 min). `zsh bench/medir.sh <rótulo>` roda a medição da detecção (`medicaoDosBends`) e a do corretor
(`medicaoDoCorretor`) nos quatro e mostra a tabela lado a lado (as medidas ficam em `medidas/<rótulo>/`, para comparar
uma mudança com a anterior). Medição da detecção
de bend (31/10, as três músicas): 2.117 notas fora de acorde das três
músicas, 171 com bend escrito; a de antes → a nova: o mesmo tipo do escrito 109 → 119, tipo e alturas 50 → 54, o som
"não dobra" 34 → 28, suspeita de altura em nota com bend escrito 74 → 62, bend de meio tom ou mais não escrito 145 → 36
(confirmados), suspeitas de bend 103 → 43 (mais 22 pelo tipo), de altura 450 → 402, notas suspeitas 553 → 454. Das três
notas em que a antiga acertava e a nova errava antes dos dois últimos ajustes (o alto pela curva rápida e o salto no
fim), duas eram erro da nova (Highway Star, c. 171 e c. 250) e uma era acerto (o "½" do c. 1 do Sunshine tinha sido
escrito pelo F antigo, e era a passagem). Com a casa pelo bend escrito (31/10, à tarde), nas músicas: o mesmo tipo 119 →
129, tipo e alturas 54 → 85, "não dobra" 28 → 18, suspeita de altura em nota com bend escrito 62 → 19, de altura 402 →
359, notas suspeitas 454 → 418 (as de bend 43 → 49: notas que eram "outra altura" passam a "dobrou meio tom a menos",
na casa certa). Segundo conjunto, de fora do repertório: os licks de `Blues Licks` no HD externo (BB King, Buddy Guy,
Johnny Winter, SRV, Clapton, Gary Moore…, Guitar Pro 8 com o áudio dentro e os pontos de sincronia; o tempo de cada
nota pelos pontos, o andamento "modificado" deles, que é o do áudio, e as curvas pelo `media/pitch.py` no MP3 de
dentro): 20 licks, 607 notas fora de acorde, 77 com bend escrito (o do Florent Passamonti, dedilhado, ficou fora).
Três estavam fora de sincronia (busca de deslocamento e escala pelas notas sem bend na altura: Billy Gibbons 1 +60 ms,
45 → 88 %; Joe Bonamassa 2 +120 ms × 0,98, 59 → 85 %; Johnny Winter 1 −630 ms × 1,0125, 42 → 76 %), e o
`FramePadding` do áudio não explica (no Joe Bonamassa 1 e no SRV 2 ele piora). Nos licks, a versão de antes → a das
músicas → esta: o mesmo tipo 63 → 63 → 65, tipo e alturas 22 → 28 → 39, suspeita de altura em nota com bend escrito
28 → 21 → 1, de altura 128 → 97 → 77, notas suspeitas (a das músicas → esta) 120 → 103. Terceiro: o `reference.gp` da
mesma pasta ("Death by Slow Blues Workout", 12/8 com anacruse, revisado pelo Miguel noutro projeto): 273 notas, 194
fora de acorde, 21 com bend escrito, quase todos de ¼ de tom; sincroniza no andamento escrito (90) com o áudio 0,69 s
adiantado (o `FramePadding` dele, −30.500 quadros; o ponto de sincronia do último compasso fica 4 s fora), 88 % das
notas sem bend na altura. Ali as duas versões de 31/10 dão o mesmo: o mesmo tipo 11 de 21, tipo e alturas 8, "não
dobra" 4, notas suspeitas 32. O que ele mostrou: das 11 notas sem bend escrito acusadas de "outra altura e bend", 6 são
slide ou ligado de uma ou duas casas abaixo (o som entra subindo e fica na escrita); nas músicas e nos licks havia 60 e
27 assim. Com a chegada e a saída das notas e a casa pelos 40 % (31/10, à noite), das notas assim sobram 31 nas músicas,
2 nos licks e nenhuma no reference; notas suspeitas 418 → 370 nas músicas, 103 → 63 nos licks, 32 → 19 no reference
(as ligações sozinhas: 412, 75, 25); de altura 359 → 311, 77 → 37, 23 → 9; bend de meio tom ou mais não escrito,
confirmado, 36 → 25, 19 → 6, 9 → 3; os bends escritos ficam como estavam (o `bend-curves.cjs` grava a chegada e a saída de
cada nota). Com o começo da nota anterior e o fim da seguinte fora da medida (31/10, à noite): o reference.gp de 19
para 14 notas suspeitas, tipo e alturas do bend escrito 8 → 12 de 21 (os ¼ de tom que saíam "1", "pré e bend" ou "pré e
volta"), os licks 63 → 61, as músicas iguais (370). Quarto conjunto, o maior: o GOAT (`GOAT.zip` em "Backup projeto" no
HD externo, o dataset do paper arXiv 2509.22655: 172 gravações de guitarra com o som direto, DI, a TAB em Guitar Pro e o
MIDI alinhado nota a nota; o jogador tocou a TAB, então ela é a verdade). Um agente montou a medição (31/10;
`bench/goat/`: `notas.cjs` e `curvas.py`, refeitos iguais pelo `refazer.sh`): o tempo de cada nota pelo MIDI do Guitar Pro casado com o
alinhado (o alphaTab não aplica o swing que o Guitar Pro toca em 15 itens), centrado no ataque; 157 itens passam da
validação de 70 % (mediana 96,7 %), 27.745 notas fora de acorde, 727 bends escritos. O que ele mostrou e mudou na
detecção (antes → depois, no GOAT; as músicas, os licks e o reference iguais ou melhores): o vibrato numa corda dobrada
oscila em volta do alto (abaixo, ou dos dois lados), e não só acima como na casa, então o alto é o pico da curva de
200 ms sem tirar a meia oscilação (com bend escrito a partir de 0,3 semitom acima da casa; sem, de ¾: um vibrato largo
na casa virava bend; o envelope de cima errava para cima nas músicas); a subida no último quarto sem nota colada depois
é o bend, se há bend escrito (15 sumiam); a volta no último quarto que solta a corda para palhetar a mesma casa de novo
não é volta, se a escrita não tem (26 de 53 "bend e volta" ouvidos); o pré-bend escrito vale a partir de 0,6 semitom, e a
janela do ataque para em 150 ms (numa nota longa engolia a volta); a entrada e a saída por slide saem da medida mesmo
quando sobram três quadros (a nota fica sem leitura; antes, 72 slides rápidos viravam bend); e o bend que não chega ao
alto escrito, de 60 % dele até ⅓ de semitom acima, é o escrito (o músico escreve a altura que quis; 24 de 1 tom saíam ½,
39 de ½ saíam ¼). No GOAT: o mesmo tipo 536 → 566 de 727, tipo e alturas 342 → 442, "não dobra" 47 → 38, bends não escritos
de meio tom ou mais confirmados 300 → 278, suspeitas de bend 344 → 293, notas suspeitas 1.190 → 1.126 (4,1 % das notas;
nos itens com 95 % ou mais de validação, ~2 %); nas músicas, tipo e alturas 85 → 104, notas suspeitas 370 → 368; nos
licks 40 → 56 e 61 → 53; o reference igual (14). Parte do ganho em "tipo e alturas" é a própria tolerância. O corretor no
GOAT muda 779 das 28.682 notas (2,7 %; antes 834); nas músicas 170, e faz as mesmas 16 das 24 correções do Miguel. O que o
GOAT mostrou e ficou para depois: a altura de outra corda que ainda soa (148 suspeitas de altura, a maioria "+3"), o
pré-bend escrito tocado como bend rápido da casa (27 de 30: é o que o músico fez), e a afinação por corda (uma só corda
de um item, −0,35 semitom). Na
linha do som da coluna, o bend em palavras (`BendForm.spoken`: "sobe 1 e volta a ½"); no gráfico do editor, tracejado,
o que o som sugere (o que o F escreveria; numa nota sem bend escrito, uma linha "O som sugere"). A linha do som e o
gráfico leem `pitchCurvesVersion` (antes podiam ficar com a medida de antes de a afinação da gravação ser refeita). Com o espectro à
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
toca até eles. Sunshine: a primeira nota soa 93 ms antes do mapa, o compasso 12 30 ms antes, o resto a menos de 25 ms. "Tudo pelo som" (⇧A no Ajuste; Editar › Sincronizar o mapa pelo som, que abre o Ajuste) faz o mesmo na música toda de uma vez (`SoundSync.synced`: o atraso de cada compasso suavizado pela mediana dos compassos com medida a até dois dele, os sem medida em linha reta entre os vizinhos, cada ponto andando o atraso do lugar dele; as âncoras ficam; até 0,25 s), num passo do Desfazer e no histórico do mapa; sem as curvas, liga a Lente e sincroniza quando a medida termina. No Sultans of Swing (31/10), o mapa do Songsterr deixava o som 45 ms antes das notas em mediana (78 % delas a mais de 30 ms, igual na multitrack e no Demucs do vídeo; do c. 191 ao fim, só 10 ms); simulado, depois: mediana 0, 31 % a mais de 30 ms e 18 % a mais de 60 ms (o que sobra é de nota a nota). Mover a nota no tempo, que a
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
restrições (~40 ms, dois quadros perdidos por segundo). Os textos que os Canvas desenham a cada quadro (os números dos
compassos, as teclas da Lente, os nomes das partes, os ms do Ajuste) são imagens feitas uma vez (`CanvasLabel`), e o
mapa da música só se redesenha quando muda, com a agulha numa camada própria a 10 quadros por segundo: medido no iMac
tocando o Sultans (1/11), a linha principal do app ocupada caiu de 75 % para 40 % do tempo (o `Text` no Canvas era
quase metade) e a página da TAB, de uns 15 quadros atrasados e paradas de até 170 ms a cada 5 s, para 0 ou 1. Z amplia a altura em volta da nota que toca (8 semitons); o botão
Inspetor (⌥⌘I, Visualizar) esconde o inspetor e as camadas ganham a largura. O transporte mostra o que ouvir (Original
ou um atalho de mixagem, `CompactMix`). Editar TAB (⌘E, `TabEditPanel`, o inspetor no modo Editar; antes de 31/10 era
uma coluna com tudo à vista e a tecla de cada comando): a nota (onde está e a figura, pelo `describe`
da página com o `placeName`; casa e meio tom com − e +; a corda, um botão por corda com a casa em que a mesma altura cai
nela, pelos `strings` do `describe`; anterior, seguinte, apagar), a duração (a figura de 1 a 1/32, pontuada, tercina,
pela `base` do `describe`, e a pausa: `length` refaz o compasso do mesmo começo, `edit.setLength`, mais curta sobra
pausa e mais longa não passa da nota seguinte; `rest` tira a batida inteira, `edit.toRest`; teclas − = . T ⇧⌫), o
bend (`BendEditor`, abaixo), as articulações em grupos, o som e o encaixe, o tempo
(barras de duração, grade, um passo para os lados), as suspeitas e, embaixo, o aviso da página, Desfazer, Refazer e
Concluir; as linhas de texto têm a altura reservada, então escolher uma nota não mexe no resto. O bend (`BendEditor`, como o
editor do Guitar Pro): o tipo (Bend, Bend e volta, Volta, Pré-bend, Pré e bend, Pré e volta; a Volta só numa ligada que
traz um bend; o tipo escolhido de novo tira), as alturas de cada etapa em quartos de tom, de ¼ a 3 tons (o pré, até onde
sobe, até onde volta), e o tempo num gráfico da nota: os pontos de arrastar na grade de 1/12, os atalhos Rápido (chega a
¼ da nota, como o Guitar Pro 8 grava), Ao longo (como o Songsterr importa) e Atrasado, e por baixo o som medido pela
Lente na batida da nota (pontos laranja; no Sunshine, c. 1, ele mostra que o "bend" de ½ escrito pelo F era o começo da
passagem à nota seguinte). B muda a altura (½, 1, 1½, 2 e tira), ⇧B o tipo. O modelo é `BendForm` (TrackLabCore,
Bend.swift): o formato do Guitar Pro 7 guarda origem, um patamar e destino (sete números, alturas ×25 por quarto de
tom, instantes em % da nota; o tipo não é gravado, sai da forma), então cada tipo tem um movimento só e o patamar de
antes do movimento se escreve como a origem atrasada; dois movimentos na mesma nota se escrevem em duas ligadas
(Dividir, Ligada). A coluna manda os pontos (`edit("bend", {points})`, em todas as escolhidas); a página confere se cabem
(`setBendPoints`: dois a quatro, em ordem, 0 a 12) e o `describe` devolve o bend da nota, a altura que a ligada traz
(`carried`) e o tempo da batida dela (`ownTick`, `ownLength`). Medido em 31/10 nos bends das músicas: ¼ e ¾ de tom, a
volta sozinha numa ligada e a subida ao longo da nota apareciam e a paleta de antes não escrevia (ela também mostrava um
bend de ¼ como "1"); 19 formas conferidas pela ida e volta do Guitar Pro 7 e pelo MIDI da TAB sintetizada (erro até ⅓
de quarto de tom, os degraus do MIDI). Fora do alcance: a volta ao chão e a subida de novo na mesma nota (o alphaTab
classifica pela forma e a reduz a um pré-bend). Várias notas de uma
vez: ⇧ clique (da nota de partida até ali, `edit.rangeOf`), ⌘ clique (põe ou tira uma) e ⇧← ⇧→ (`extend`); a página
guarda `group` (os endereços) e a principal, contorna as outras (`#group-selection`) e manda à coluna quantas são, de
onde a onde e o trecho em tiques. Articulação (liga em todas se a principal não tem, `toggleAll`), casa e meio tom
(`transposeAll`), corda (`moveAll`, o trecho noutra posição do braço), apagar, pausa, figura e ⌥← ⌥→ valem para todas;
as do ritmo uma batida por vez, com o finish entre uma e outra (`eachBeat`). Se uma não dá, nenhuma muda: o `change`
volta a partitura de antes (também numa só, que um compasso refeito pela metade deixava estragada). Esc com várias deixa
só a principal; os passos do Desfazer guardam a escolha. Reconhecer um trecho (`Recognize.swift`, `Recognition` em
TrackLabCore): ⌥ + arrastar na Lente marca um retângulo de tempo × altura (o ⌥ do "só a altura" de uma faixa arrastada
vale ao soltar); o motor ouve de novo só aquele pedaço da faixa onde a pista soa e só naquela faixa de alturas
(`transcribe`), o app escreve as notas (`Recognition.notes`: a altura, o bend e o vibrato pelo encaixe do F, com a
afinação da gravação descontada; o começo e o fim na grade escolhida, a nota esticando até a seguinte se sobra menos de
um passo; a corda onde a casa fica mais perto da nota tocada antes do trecho, a mesma da nota que estava ali com essa
altura, e a mesma da anterior num slide; a nota de onde sai um slide fica sem bend, porque a subida no fim dela é o
slide) e a coluna da edição mostra dois cartões, "Como está" e "Reconhecido" (as
notas em faixas sobre os pontos do som, com a casa), e a Lente as notas achadas tracejadas em verde. Um clique no
reconhecido troca (`edit("replaceRegion")`, `edit.replaceRegion`, num passo do Desfazer): as notas da faixa de alturas
que começam no trecho saem, a que vinha de antes nessa faixa encurta até ele (ou continua, quando a primeira achada é a
mesma altura no começo do trecho, `continues`), e entram as novas, com o slide da anterior (Legato), o de fora, o
vibrato e o bend; as outras notas ficam, e o que soa junto vira acorde, com a nota que atravessa o começo de outra
cortada ali em ligadas (cada parte com o vibrato, o bend repartido no tempo). Uma corda dupla se faz em dois
retângulos. Provado no c. 105/106 do Sultans, no app (aplicado, conferido e desfeito, com backup): o 12 → 14 de
semicolcheia sai 11, slide, 14 segurado com vibrato até o fim do c. 106, em acorde com o 13 da corda Mi, como soa. Ouvir (o ouvido, O ou ⌥Espaço, que no Mac do Miguel é o atalho global do ChatGPT) põe o loop no trecho escolhido e
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
numa nota ligada reparte o bend medido entre as partes (`fitChain`) e põe o vibrato nas partes em que o som vibra
(`vibratoFrom` e `vibratoTo`, a fração da cadeia onde ele começa e acaba, de `CurveFit.vibratoStart`, o começo da
primeira meia volta, e `vibratoEnd`, o fim da última: a parte em que ao menos um quarto cai dentro dele, e as outras
ficam sem; nenhuma assim, a que tem mais; com bend, só depois de o bend chegar ao alto; sem a medida, a nota inteira sem
bend e a última com bend). Antes ia só à última, e o F nem mandava quando uma parte já tinha vibrato: no Sultans of
Swing, c. 5, um Ré de três ligadas vibrando do começo ao fim ficava com o vibrato só no fim da TAB, e no c. 27 um Dó que
vibra no começo e acaba antes do fim da escrita ficava com ele só na segunda parte. "Corrigir pelo som" também leva o
vibrato já escrito das ligadas sem bend às partes em que o som vibra (sem marcar a nota). Na Lente, a faixa de uma nota
com vibrato segue o do som onde ele tem altura e fica lisa onde não tem (antes ganhava a onda escrita onde o som tinha
acabado, e o vibrato parecia mais longo que no espectro). O vibrato do som (`SoundNote.fit`) conta cada meia volta em
volta da curva de 200 ms pela distância de pico a vale (o alto dela mais o da anterior), de 0,2 semitom para cima, e a
largura (`depth`) é a metade disso; antes cada metade tinha de passar de 0,12 semitom da média sozinha, e o vibrato da
guitarra que empurra a corda para cima da casa e volta escapava (no Sultans of Swing, c. 42, a corda dupla Lá e Fá na
casa 10, a de cima vibrando 0,2 semitom). Um vibrato estreito também vale quando é regular: seis voltas seguidas ou
mais de 0,1 semitom de pico a vale, de 4 a 9 por segundo, cada meia volta a até 35 % da duração média, cobrindo metade do
trecho medido (no c. 106 do Sultans, o Fá da casa 13 vibra ±7 cents a 8 Hz por 1,2 s; no GOAT, dos 227 vibratos escritos
o som passa a mostrar 151, antes 149, e 23 notas a mais "vibram" sem estar escritas, das 27.745). O corretor só escreve sozinho o vibrato de largura 0,12 para cima
(`SoundNote.writtenVibrato`; com a detecção nova, no GOAT, ele passava a pôr 50 a mais, quase todos sutis: assim põe 11), e
numa corda dupla (duas notas na mesma batida, `doubleStopVibrato`) põe o vibrato nas duas quando as duas o mostram, uma
com essa largura e nenhuma acima de meio semitom (a curva de acorde, pelos harmônicos, dá saltos que parecem vibrato
largo: a 8/9 do c. 42 "vibrava" 0,59 na de baixo e nada na de cima, e ganhava o vibrato); o corretor de nota não mexe em
acordes, e com três notas ou mais, nada. Ligada (L, a primeira de Ligados e slides,
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
Aparência: do sistema, clara (papel: a Onda com o fundo creme e as marcas escuras; a Lente fica escura) ou escura. Fontes › Multitracks › "Procurar a TAB" abre a busca do Songsterr com o
nome da multitrack; a música importada vem sem o Demucs e com as faixas dela (`importMultitrack(path:)`), a não ser
num .mogg. No mixer, a linha
TAB tem uma faixa por pista sintetizada (ids `tab:<pista>`, a 80 % ao chegar, com o grupo TAB desligado), que soa por cima do original ou das
faixas; mudo e solo valem dentro de cada grupo, o áudio (as faixas da separação) e a TAB (`mixGains`, `isSynth`; antes um solo valia para tudo e soltar uma pista da TAB calava o áudio e o original), e a chave geral "Áudio" fica no começo da linha das faixas, a "TAB" e o X na da TAB (31/10; antes as duas ficavam juntas na da TAB e o Miguel achava que as pistas da TAB eram as faixas da multitrack). Os atalhos de mixagem (`MixPreset.apply`) mexem só nas faixas
da separação e tiram os solos do áudio (o da TAB, outro grupo, fica): antes devolviam só elas, as pistas da TAB perdiam a entrada e ficavam em volume zero (a
TAB e o X não soavam com uma separação ativa). A WKWebView da partitura (`ScoreWebView`) não aceita o foco
do teclado: com ele, engolia espaço, setas e letras depois de um clique na TAB e os atalhos do transporte paravam; um
clique na TAB ou na Fita também tira o foco de um campo de texto (a busca). Com mais de uma separação guardada, o A/B
abre pronto para a seguinte na escada.

Barra de acordes (1/11; `ChordLane`, `Chords.swift` no app e em TrackLabCore): uma faixa fina entre a TAB e a Onda, na
escala da Fita, ligada e desligada no menu Visão (⌥⌘3, `chordsVisible`), fora das páginas. Os acordes saem das notas de
todas as pistas (`ChordReader`): cada pista pesa pelo papel, que vem do nome dela (`HarmonyRole`: a base 1, guitarra e
teclado 0,8, uma nota sozinha mais curta que um tempo nelas 0,4 disso (a frase de notas soltas da introdução do Ramblin'
Man, numa pista "Rhythm Guitar", virava um acorde por nota), a lead, o slide, as harmonias e as melodias 0,9 onde tocam
acorde, duas notas ou mais juntas, e 0,12 nas frases, o baixo 0,35 mais a nota grave, a voz 0,08, a bateria nada); a
cada colcheia, o peso de cada uma das 12 notas (a segurada perde peso com o tempo), visto um tempo para cada lado (pesos
1, 2, 3, 2, 1), contra 13 qualidades (maior, menor, 5, 7, m7, maj7, sus4, sus2, add9, 9, dim, m7b5, aug; a quinta pode
faltar, a terça não; a sétima e a nona só contam com 14 % do peso; o mais raro custa mais; o baixo na fundamental soma
pela parte do tempo em que está nela; o 6 e o m6 saíram: no rock a sexta é enfeite, o pedaço C+G+E♭ dentro do Mi♭) e o
caminho mais provável (Viterbi: trocar custa 0,4 no 1 do compasso, 0,7 no meio dele, 1,1 num tempo e 1,6 fora do tempo,
e um passo quase vazio segue o acorde de antes). Depois, um trecho mais curto que meio compasso que o vizinho explica
quase tão bem (até 0,3 a menos) vira parte dele, a não ser que o baixo fique na fundamental dele 60 % do trecho (uma
troca de verdade); dois vizinhos com a mesma fundamental, um variação do outro (sus, add9, 7, maj7), viram um; e entre
leituras com as mesmas notas (Cm7 e Eb, Fm7 e Ab, Bbm7 e Db) vale a do baixo que abre o trecho (o baixo andando pela
sexta fazia o Mi♭ do Ramblin' virar Cm7). O baixo noutra nota do acorde 70 % do trecho vira barra ("C/G"). A grafia
segue o tom (os perfis de Krumhansl sobre as notas de tudo): bemóis em Fá, Si♭, Mi♭, Lá♭, Ré♭ e Sol♭ maior e nas
relativas, sustenidos nas notas da escala dos tons de sustenidos, e a de costume no resto (Bb, Eb, Ab, C#, F#); os
escritos passam para ela ("A♭" vira "Ab", "C5 \G" vira "C5/G"; antes o Ramblin' mostrava C# lido ao lado do D♭ escrito).
Por cima, os escritos no Guitar Pro (do tique deles até a troca lida seguinte, ou desde o começo do lido com a mesma
fundamental: o Songsterr pôs os do Ramblin' no 2; no mesmo tique, o da pista de base) e, por cima de tudo, as correções.
Medido sem os escritos, quantos deles a leitura acha (a fundamental e a terça no meio do escrito; 5 e sus valem com
qualquer terça) e as trocas por compasso, antes → depois dos ajustes de 1/11: Ramblin' Man 78/93 e 1,70 → 85/93 e 0,65;
Sunshine 31/49 e 2,92 → 46/49 e 1,02; Highway Star 165 escritos (muitos power chords no contratempo, que agora ficam no
acorde do compasso) e 1,12 → 0,55; Sultans 18/20 e 0,92 → 20/20 e 0,80; White Room (sem escritos) 2,15 → 1,44. No Sultans,
a progressão do disco (Dm C Bb A no verso, F C Bb no refrão, Dm C Bb C no fim); no Ramblin', um acorde por compasso na
introdução e no verso. Fica difícil: o solo final do Ramblin' (a base em duas notas sobre o baixo andando, sem escritos)
e os riffs de notas soltas (a White Room ainda dá sus2 e dim de passagem). A leitura roda
fora da linha principal (310 ms em debug no Sultans), 150 ms depois da última mudança de notas, pistas ou escritos; uma
correção só refaz a camada de cima. Na barra: o bloco de cada acorde com o nome (o que toca em âmbar, o escolhido
contornado, o corrigido com um ponto, o escrito com um traço embaixo); um clique leva a música ao acorde sem a tela
saltar; duplo clique renomeia (com os nomes que as notas também aceitam; vazio é N.C.); arrastar a divisa entre dois leva
a troca, na grade de colcheias; arrastar no meio marca o loop; o botão direito tem os outros nomes, renomear, dividir no
clique, juntar com o vizinho, sem acorde, voltar ao lido, ouvir (`NoteSynth` toca acordes, violão de aço) e loop. As
correções vão ao motor uma gravação por vez e andam com os compassos postos ou apagados. O som (1/11): o app pede ao
motor os acordes pelo som presos às batidas do mapa (`hearChords`, um segundo depois de o mapa mudar; "ouvindo os
acordes…" na barra na primeira vez) e eles entram na leitura como outra prova (`ChordReader.read(sound:)`): o acorde
que o som ouve em cada passo vira candidato e soma no caminho com peso pela clareza da TAB ali (`soundWeight`: 0,1 com
um acorde claro nas notas, até 1 num riff ou numa frase; com peso fixo, o som puxava o G curto do refrão do Sunshine
para o A que ele ouvia), também na hora de absorver os trechos curtos; o nome sem terça das notas (D5, Csus2) vira o do
som quando ele ouve a mesma fundamental com terça; e cada trecho guarda o que o som ouviu (`heard`) e é marcado para
conferir (`disputed`, uma linha laranja embaixo do bloco) quando o som discorda dele (outra fundamental ou a terça
trocada) em 60 % de ao menos dois tempos. O menu do acorde diz "o som ouve X" e tem "Usar o do som". Medido (os escritos
achados sem os escritos, as trocas por compasso), só as notas → com o som: Ramblin' Man 85 → 88 de 93 e 0,65 → 0,62
(o fim, Fm7, passa a Gb Db, o que soa); Sunshine 46 → 46 e 1,02 → 0,75; Highway Star 113 → 112 e 0,55 → 0,52; Sultans
20 → 19 e 0,80 → 0,76; White Room 1,44 → 1,45, o verso de sus2 e dim do riff passa a D C | G/B C, o disco. Dois
deslocamentos que o Guitar Pro não diz: uma pista fora do disco por um intervalo fixo (`trackShifts`, pista por pista: o
deslocamento que põe mais tempo de nota dela dentro do acorde que o som ouve, com metade dentro e 15 % a mais que sem
deslocar; a voz e a bateria não mudam; no Here Comes the Sun as guitarras estão pelas formas do capo 7 com o capo 0 no
arquivo, +7, e o baixo na altura certa: deslocando tudo junto, como na primeira versão, o baixo virava a barra errada,
"A/E", "D/A", "E7/B"; no Michelle a gravação está meio tom abaixo da afinação da TAB), e as notas entram já no que soa
(`tabShift` é o da guitarra de base, para o nome da forma nos diagramas); e os escritos pelas formas do violão numa guitarra afinada abaixo (`shapeShift`: o Yesterday, um tom abaixo,
escrito G F#m B7 e soando F Em A7), mostrados no que soa, com a forma entre os outros nomes. A Lente desses dois ainda
mostra as notas da TAB fora do espectro (o capo e a afinação do GP não mudaram). Medido nos Beatles (1/11) contra as
anotações da Isophonics (Harte, os acordes dos discos; o deslocamento até o áudio do vídeo pelo melhor acordo com o
som, em ±12 s), a fração do tempo com a fundamental e a terça certas, só a TAB / só o som / os dois / a barra com os
escritos: Let It Be 89/90/88/85, Help! 91/87/94/94, Yesterday 81/85/87/81, Here Comes the Sun 31/89/87/86 (78/78 com o
deslocamento da TAB inteira), Michelle 0/72/75/77 (o Chord-CNN-LSTM foi treinado com a Isophonics: a coluna do som sai otimista). Dos 10 Beatles importados
(Let It Be, Help!, Yesterday, Something, Here Comes the Sun, Day Tripper, Norwegian Wood, Penny Lane, A Hard Day's
Night, Michelle; sem o Demucs), Something, Norwegian Wood, Penny Lane e A Hard Day's Night vieram sem áudio (o Songsterr
não tinha sincronia) e o Day Tripper não está na Isophonics. A leitura de fora do app: `node web/tools/chord-notes.cjs
<gp> <json>` e `TRACKLAB_CHORDS_NOTES=<json> [TRACKLAB_CHORDS_SOUND=<json em tiques>] [TRACKLAB_CHORDS_FINAL=<json>]
mac/test.sh --filter acordesDeUmaMusica` (compasso a compasso, com "?" e o que o som ouve onde discorda).

Diagramas de acorde (1/11; `ChordDiagram.swift`, `TrackLabCore/ChordShapes.swift`): as digitações vêm do chords-db
(tombatossals, MIT, o `guitar.json` do commit df06fa7b em `mac/Resources/chords-db`, que o `build.sh` copia para o app;
os Guitar Pro do Songsterr trazem a coleção de diagramas vazia, e o alphaTab só desenha as que vêm no arquivo).
`ChordLibrary` lê as casas (relativas à casa inicial na base, absolutas aqui) e acha pelo nome da barra (C, Am7, C/G e
Am/G pelas inversões da base, "C(add9)" sem os parênteses, um nome que a base não tem pelo mais perto: Cmadd11 → Cm).
A primeira digitação é a que a TAB toca no trecho (`ChordShape.played`: a batida com mais cordas de uma vez, ao menos
três, numa pista de guitarra de seis cordas, a base primeiro; desenhada em laranja, "como na TAB"); as da base vêm em
ordem de distância até onde a mão está na TAB. Com a TAB inteira deslocada do disco (`chordTabShift`, o capo do Here
Comes the Sun), a forma procurada é a do braço ("forma de D" sob o Lá que soa). O desenho é nativo (Canvas: seis cordas,
quatro casas, a pestana, os dedos da base, X e O, a casa inicial ao lado). No inspetor do Estudar, o grupo Acordes mostra
o acorde que toca (ou o escolhido na barra, com a música parada) e o seguinte, cada um com ‹ › entre as digitações e o
alto-falante (a forma tocada no `NoteSynth`, afinação padrão). O capo: a página manda o de cada pista (`capos`, com as
notas), e o da guitarra de base é o do GP mais o que o som mostra que falta (`capoFret`; "forma de D · capo 7ª" sob o
diagrama, "Capo 7ª" no grupo). Quando a guitarra de base não soa onde a TAB diz, o grupo propõe a correção
(`pitchFixProposal`): acima, "Pôr capo 7 na partitura" nas guitarras com o mesmo deslocamento; abaixo, "Afinar a TAB meio
tom abaixo" nas pistas com ele (o Michelle). A página aplica (`edit("pitchFix", [{track, capo}|{track, tune}])`,
`edit.pitchFix`: o capo da pauta, que o alphaTab soma na altura de cada nota, ou a afinação de todas as cordas; as casas
ficam), num passo do Desfazer da TAB, grava o Guitar Pro e a TAB sintetizada é refeita (`resynthAfterSave`); a Lente, a
TAB sintetizada e a leitura dos acordes passam a soar como o disco. Numa música com capo, os nomes da barra, dos cartões e
do menu podem ser como soam ou pela forma do capo (`chordsByShape`, guardado, no grupo Acordes "Como soam | Pela forma" e
no menu do acorde; `shown` e `sounding(fromShown:)`: o que se escreve ao renomear pela forma é guardado como soa); o
cartão diz o outro ("soa A · capo 7ª" ou "forma de D · capo 7ª"). O capo e as pistas de guitarra ficam guardados
(`chordCapo`, `chordGuitarTracks`, refeitos por `updateCapo` quando as notas, o capo do GP ou o deslocamento mudam) e as
digitações dos cartões também (`shapeCache`): a barra perguntava o capo a cada nome de cada quadro, e calculá-lo percorria
todas as notas (no Something tocando, a barra tomava 35 % da linha principal e a rolagem engasgava; agora 1,5 %).

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
