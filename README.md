# TrackLab

Estúdio de estudo de guitarra para o Mac. Você busca a música no Songsterr, o TrackLab prepara a tablatura, o áudio
e as faixas separadas, e a música entra no seu repertório. A TAB e a onda andam num relógio só; o alinhamento é
seu, ajustado à mão com as ferramentas do TabLab.

Nasce de três projetos anteriores: BackingLab 2 (importação do Songsterr, separação, gravação), KaraokeLab (motor
local com fila, StemEngine) e TabLab (mapa de batida e ajuste manual).

- `engine/` — o motor local em Python (uv): pacotes de música, Songsterr, Demucs 6s, API em 127.0.0.1 com SSE.
- `mac/` — o app nativo (SwiftUI, macOS 15): repertório, importação, partitura, Fita, loop, velocidade, tom e mixer.
- `web/` — a página da partitura (alphaTab 1.8.4, MPL-2.0) que o app abre numa WKWebView.

Primeiro no iMac Intel (macOS 15, Radeon Pro 580X), depois no Apple Silicon com o mesmo código.
Proposta de design: https://claude.ai/artifact/EomP8enfZv8mW3S46N5ycf
