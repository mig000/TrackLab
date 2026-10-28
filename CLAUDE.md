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
  nome quando está inteiro; cada separação idem dentro de `stems/`.
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
- `jobs.py` (do TabLab: um worker, eventos em disco e por SSE), `api.py` (FastAPI), `cli.py` (`tracklab serve
  --port 0 --parent-pid N` imprime `TRACKLAB_PORT=<n>`; o motor é do app e sai com ele).
- O lock universal fixa torch 2.2.2 / numpy 1.26 (o demucs 4.1.0 exige isso no macOS x86_64); separar por
  plataforma na fase do Apple Silicon.

## Partitura (`web/`)
`score.html` + `score.js` desenham o GP do pacote com o alphaTab (horizontal, só TAB, uma pista por vez) e não têm
áudio: o app empurra o relógio e o mapa de tempo; segundos → tiques pelo mapa → x pelas batidas desenhadas
(`absolutePlaybackStart`, `onNotesX`; o fim de cada compasso). O cursor fica parado a 40 % da largura e a pauta
rola. As contas puras ficam em `score-core.js`; `node web/tests/check-score.cjs` as confere e desenha os GPs de
`tests/fixtures` (feitos pelo conversor do motor) no alphaTab do node: os tiques do alphaTab batem com os do mapa.
O conversor não escreve repetições, então os pontos do Songsterr são um por compasso escrito.

## App (`mac/`)
SwiftPM sem Xcode (`./build.sh` → build/TrackLab.app, `./test.sh`), alvo macOS 15, Swift 6 em modo 5. Estado das
views por `@Local` (= SwiftUI.State). `Backend` inicia `engine/.venv/bin/tracklab serve --port 0 --parent-pid`,
lê a porta do stdout (`TRACKLAB_URL` aponta para outro motor). `StemEngine`: o original e as seis faixas num
AVAudioEngine, início comum em tempo de host, um TimePitch (velocidade 0,5–1,5, tom ±6); o loop é agendado no
player (`PlaybackPlan`: até o fim do loop e o loop de novo, 20 min por vez), sem seek a cada volta. `SongModel`
abre a música (manifesto, mapa, ondas, áudio, GP); a mixagem abre em "Sem guitarra". `FitaView`: a onda do
original e a da guitarra sob a agulha a 40 %; clique = seek, arrasto = loop preso nas batidas. TrackLabCore
(modelos, `TempoGrid`, `mixGains`, `MixPreset`, `PlaybackPlan`) tem os testes.

## Ambiente
- A nuvem não alcança songsterr.com nem huggingface.co: a importação real e a separação se provam no iMac.
- O iMac não tem uv nem checkouts; o BackingLab 2 Intel (build 43) instalado lá não deve ser alterado.
- A nuvem não tem Swift: o app só compila no iMac (Command Line Tools, Swift 6.2).
