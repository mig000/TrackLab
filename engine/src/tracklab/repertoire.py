"""O repertório: o estado de estudo de cada música, os trechos com meta de velocidade e o que foi treinado.

Tudo fica no manifesto do pacote (`status`, `sections`), então vai junto quando a pasta muda de Mac:

    "status": "want" | "learning" | "polishing" | "repertoire" | "archived"
    "sections": [{"id": "sec-…", "name": "Riff", "from": 3840, "to": 7680, "goal": 100,
                  "best": 85, "practiced": "2026-10-28T…", "history": [{"at": "…", "rate": 85, "clean": true}, …]}]

`from` e `to` são tiques da partitura (960 por semínima): o trecho fica nos compassos mesmo quando o mapa de tempo
muda. `goal` e `best` são a velocidade em %, `best` a maior tocada limpa. O app escolhe o que fazer hoje com isso.
"""

from __future__ import annotations

import math

from .errors import TrackLabError
from .util import new_id, now_iso

STATUSES = ("want", "learning", "polishing", "repertoire", "archived")
DEFAULT_STATUS = "want"
DEFAULT_GOAL = 100
GOALS = (50, 150)  # a velocidade do motor de áudio vai de 50 a 150 %
HISTORY_LIMIT = 200
NAME_LIMIT = 60


class RepertoireError(TrackLabError):
    """Estado, trecho ou treino que o repertório não aceita."""


def check_status(status) -> str:
    if status not in STATUSES:
        raise RepertoireError(f"Estado desconhecido: {status!r}. Use {', '.join(STATUSES)}.")
    return status


def merge_sections(old: list[dict], new: list) -> list[dict]:
    """Os trechos enviados pelo app (nome, compassos e meta), em ordem de início; o treino de cada um (recorde,
    última vez, histórico) vem do que já estava guardado com o mesmo id e nunca é mandado pelo app."""
    if not isinstance(new, list):
        raise RepertoireError("Envie os trechos como uma lista.")
    kept = {section["id"]: section for section in old if isinstance(section, dict) and "id" in section}
    result = []
    for raw in new:
        if not isinstance(raw, dict):
            raise RepertoireError("Cada trecho é um objeto com nome, from e to.")
        start, end = raw.get("from"), raw.get("to")
        if not (_number(start) and _number(end)) or start < 0 or end <= start:
            raise RepertoireError("Um trecho precisa de from e to em tiques, com to depois de from.")
        name = str(raw.get("name") or "").strip()[:NAME_LIMIT]
        if not name:
            raise RepertoireError("Todo trecho precisa de um nome.")
        goal = raw.get("goal", DEFAULT_GOAL)
        if not _number(goal) or not GOALS[0] <= goal <= GOALS[1]:
            raise RepertoireError(f"A meta é uma velocidade de {GOALS[0]} a {GOALS[1]} %.")
        section_id = raw.get("id") if isinstance(raw.get("id"), str) and raw.get("id") else new_id("sec")
        previous = kept.get(section_id, {})
        result.append({"id": section_id, "name": name, "from": start, "to": end, "goal": round(goal),
                       "best": previous.get("best"), "practiced": previous.get("practiced"),
                       "history": previous.get("history", [])})
    result.sort(key=lambda section: section["from"])
    return result


def record_practice(section: dict, rate, clean: bool) -> dict:
    """Uma passada pelo trecho na velocidade `rate` (%): limpa ou não. Guarda a hora, o histórico (os últimos
    `HISTORY_LIMIT`) e, se limpa, o recorde."""
    if not _number(rate) or not GOALS[0] <= rate <= GOALS[1]:
        raise RepertoireError(f"A velocidade é de {GOALS[0]} a {GOALS[1]} %.")
    rate = round(rate)
    at = now_iso()
    history = (section.get("history") or []) + [{"at": at, "rate": rate, "clean": bool(clean)}]
    best = section.get("best")
    if clean and (best is None or rate > best):
        best = rate
    return {**section, "best": best, "practiced": at, "history": history[-HISTORY_LIMIT:]}


def study_summary(manifest: dict) -> dict:
    """O que a lista e o Para hoje precisam de uma música: estado, trechos (sem o histórico), afinação da pista de
    guitarra, compassos conferidos e avisos."""
    score = manifest.get("score") or {}
    tracks = score.get("tracks") or []
    guitar = next((t for t in tracks if _is_guitar(t)), tracks[0] if tracks else None)
    return {
        "status": manifest.get("status") or DEFAULT_STATUS,
        "sections": [{key: section.get(key) for key in ("id", "name", "from", "to", "goal", "best", "practiced")}
                     for section in manifest.get("sections") or []],
        "tuning": (guitar or {}).get("tuning"),
        "measures": score.get("measures"),
        "checked": len(manifest.get("checkedBars") or []),
        "warnings": len(manifest.get("warnings") or []),
    }


def _is_guitar(track: dict) -> bool:
    """A mesma regra do app: guitarra e não baixo."""
    text = f"{track.get('name') or ''} {track.get('instrument') or ''}".lower()
    return "guitar" in text and "bass" not in text


def _number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
