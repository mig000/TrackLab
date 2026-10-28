"""Linha de comando do motor: importar, separar, listar e servir a API para o app."""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import threading
import time

from . import package, songsterr, stems
from .errors import TrackLabError


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tracklab")
    commands = parser.add_subparsers(dest="command", required=True)
    find = commands.add_parser("search", help="buscar no Songsterr")
    find.add_argument("query")
    imp = commands.add_parser("import", help="importar uma música do Songsterr para o repertório")
    imp.add_argument("url")
    imp.add_argument("--no-separate", action="store_true", help="não separar as faixas agora")
    sep = commands.add_parser("separate", help="separar as faixas de uma música do repertório")
    sep.add_argument("song")
    sep.add_argument("--device", choices=("mps", "cpu"))
    commands.add_parser("list", help="listar o repertório")
    serve = commands.add_parser("serve", help="servir a API em 127.0.0.1")
    serve.add_argument("--port", type=int, default=8780, help="0 deixa o sistema escolher; a porta sai no stdout")
    serve.add_argument("--parent-pid", type=int, help="encerrar quando este processo (o app) terminar")
    args = parser.parse_args(argv)
    try:
        if args.command == "search":
            for item in songsterr.search(args.query):
                print(f"{item['id']:>8}  {item['artist']} - {item['title']} ({item['tracks']} faixas)")
        elif args.command == "import":
            made = songsterr.import_song(args.url, progress=_print)
            print(json.dumps(made.summary(), ensure_ascii=False, indent=2))
            for warning in made.manifest.get("warnings", []):
                print("aviso:", warning)
            if not args.no_separate and made.manifest.get("audio"):
                _report(stems.separate_song(made, progress=_print))
        elif args.command == "separate":
            _report(stems.separate_song(package.find(args.song), progress=_print, device=args.device))
        elif args.command == "list":
            for item in package.packages():
                print(json.dumps(item.summary(), ensure_ascii=False))
        elif args.command == "serve":
            _serve(args.port, args.parent_pid)
    except TrackLabError as error:
        print(f"erro: {error}", file=sys.stderr)
        return 1
    return 0


def _print(stage: str, message: str, fraction: float | None = None) -> None:
    share = "" if fraction is None else f" {fraction * 100:5.1f}%"
    print(f"[{stage}]{share} {message}", file=sys.stderr, flush=True)


def _report(result: dict) -> None:
    where = "reaproveitadas" if result.get("reused") else f"em {result.get('seconds')} s ({result.get('device')})"
    print(f"faixas {result['key']}: {where}")
    if result.get("fallback"):
        print("aviso:", result["fallback"])


def _serve(port: int, parent: int | None) -> None:
    import uvicorn

    from .api import create_app

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
    # O app lê esta linha para saber onde falar com o motor.
    print(f"TRACKLAB_PORT={sock.getsockname()[1]}", flush=True)
    if parent:
        threading.Thread(target=_watch, args=(parent,), daemon=True).start()
    app = create_app()
    try:
        uvicorn.Server(uvicorn.Config(app, log_level="warning")).run(sockets=[sock])
    finally:
        app.state.jobs.close()


def _watch(parent: int) -> None:
    """O motor é do app: quando o app some (até num crash), o motor sai junto."""
    while True:
        time.sleep(1.0)
        try:
            os.kill(parent, 0)
        except ProcessLookupError:
            os._exit(0)
        except PermissionError:
            pass
        if os.getppid() == 1:
            os._exit(0)


if __name__ == "__main__":
    sys.exit(main())
