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
  o anterior em `score/tempo-map-history/` (as últimas 200 versões).
- `tempomap.py`: o contrato do mapa de batida do TabLab (tiques a 960 por semínima, pontos anchor / detected /
  interpolated, âncoras com alcance de 8 batidas), copiado do backend do TabLab (`integracao`), mais
  `from_bar_starts` (os pontos do Songsterr: início de cada compasso vira `detected`, as batidas de dentro
  `interpolated`).
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
`score.html` + `score.js` desenham o GP do pacote com o alphaTab (horizontal, só TAB, uma pista por vez) e não têm
áudio: o app empurra o relógio e o mapa de tempo. A TAB tem a escala da Fita (`span` segundos na largura): cada
compasso ganha `displayWidth` = duração × px/s (descontada a clave e a fórmula, medidas num primeiro desenho de cada
pista), as barras caem sobre as da Fita e a pauta corre sob o cursor parado a 40 %, na velocidade da Fita. O
alphaTab de `vendor/` tem dois ajustes marcados `TrackLab:` (notas espaçadas pela duração; o número do compasso não
ocupa largura). O relógio leva o atraso da saída de áudio (`delay`, ~0,15 s no iMac): a página só anda quando o som
sai. As contas puras ficam em `score-core.js`; `node web/tests/check-score.cjs` as confere e desenha os GPs de
`tests/fixtures` (feitos pelo conversor do motor) no alphaTab do node: os tiques batem com os do mapa, e barras e notas
caem no tempo.
O conversor não escreve repetições, então os pontos do Songsterr são um por compasso escrito.

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
batidas ou até a próxima âncora), duplo clique prende ou solta, U leva o 1 mais perto até o toque; ⌘Z / ⇧⌘Z pelo
menu Editar (sem ajuste a desfazer, vão para a cadeia de respondedores). TrackLabCore (modelos, `TempoGrid`,
`mixGains`, `MixPreset`, `PlaybackPlan`) tem os testes.

## Ambiente
- A nuvem não alcança songsterr.com nem huggingface.co: a importação real e a separação se provam no iMac.
- O iMac tem uv e este checkout em `~/Claude/TrackLab` (desde 28/10); o BackingLab 2 Intel (build 43) instalado lá não
  deve ser alterado.
- A nuvem não tem Swift: o app só compila no iMac (Swift 6.2; `test.sh` usa o Xcode 26.3 de lá, porque as CLT 26
  não trazem o módulo Testing).
- Primeira prova real (28/10, iMac): Sunshine of Your Love do Songsterr em 92 s, Demucs 6s 82,5 s na GPU sem recair
  para a CPU; o app conecta, lista o repertório e o motor sai com ele.
