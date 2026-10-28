# Motor do TrackLab

O motor local do app: importa músicas do Songsterr para o repertório (um pacote `.tracklab` por música), separa as
faixas com o Demucs 6s (GPU quando houver) e serve uma API em 127.0.0.1 para o app nativo, com uma fila de tarefas e
progresso por SSE.

```bash
cd engine
uv sync --extra separate --group dev   # sem --extra separate: tudo menos a separação
uv run pytest
uv run tracklab search "sunshine of your love"
uv run tracklab import https://www.songsterr.com/a/wsa/cream-sunshine-of-your-love-tab-s27
uv run tracklab list
uv run tracklab serve --port 0 --parent-pid <pid do app>   # imprime TRACKLAB_PORT=<n>
```

O repertório fica em `~/TrackLab/Repertorio` e os modelos em `~/TrackLab/Modelos` (`TRACKLAB_HOME` e
`TRACKLAB_MODELS` mudam isso). Precisa do `ffmpeg` (Homebrew). O `node` do Homebrew ajuda o yt-dlp quando o YouTube
pede um runtime JavaScript.

No Intel, o `demucs` 4.1.0 instala o torch 2.2.2, o último para macOS x86_64; na Fase 0 o Demucs 6s rodou na
Radeon Pro 580X pelo MPS com o mesmo resultado da CPU, umas 4× mais rápido. Se o MPS recusar uma operação, a
separação termina na CPU e o pacote registra o motivo.
