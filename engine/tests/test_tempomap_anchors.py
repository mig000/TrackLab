"""O ajuste fino da batida: levar uma batida a um segundo mexe só até as âncoras vizinhas."""

import pytest

from tracklab.tempomap import RhythmError, map_of, move_anchor, release_anchor


def grid(seconds: list[float], anchors: tuple[int, ...] = ()) -> dict:
    return {"schemaVersion": 1, "source": "audio",
            "points": [{"tick": 960 * k, "seconds": s, "kind": "anchor" if k in anchors else "detected"}
                       for k, s in enumerate(seconds)]}


def times(tempo_map: dict) -> list[float]:
    return [round(p["seconds"], 6) for p in tempo_map["points"]]


def test_moving_between_anchors_stretches_only_the_two_neighbouring_spans():
    before = grid([0.0, 0.5, 1.1, 1.5, 2.0, 2.5, 3.0], anchors=(0, 4))
    after = move_anchor(before, 1920, 1.2)
    # Até a âncora da esquerda (0 s), na proporção: 0,5 de 1,1 → 0,5·1,2/1,1.
    assert times(after)[:3] == [0.0, round(0.5 * 1.2 / 1.1, 6), 1.2]
    # Da nova até a âncora da direita (2 s): 1,5 ficava a 0,4 de 0,9 → 1,2 + 0,8·0,4/0,9.
    assert times(after)[3] == round(1.2 + 0.8 * 0.4 / 0.9, 6) and times(after)[4:] == [2.0, 2.5, 3.0]
    moved = next(p for p in after["points"] if p["tick"] == 1920)
    assert moved["kind"] == "anchor" and moved["confidence"] == 1.0


def test_without_an_anchor_on_one_side_that_side_moves_along():
    after = move_anchor(grid([0.0, 0.5, 1.0, 1.5]), 960, 0.6)
    assert times(after) == [0.1, 0.6, 1.1, 1.6]


def test_a_tick_between_points_becomes_a_point_and_the_beat_cannot_pass_an_anchor():
    before = grid([0.0, 0.5, 1.0, 1.5], anchors=(0, 3))
    after = move_anchor(before, 1440, 0.8)
    assert [p["tick"] for p in after["points"]] == [0, 960, 1440, 1920, 2880]
    assert map_of(after).seconds(1440) == pytest.approx(0.8)
    with pytest.raises(RhythmError):
        move_anchor(before, 960, 1.6)


def test_release_keeps_the_place_and_drops_the_anchor():
    after = release_anchor(move_anchor(grid([0.0, 0.5, 1.0]), 960, 0.55), 960)
    assert times(after) == [0.05, 0.55, 1.05] and all(p["kind"] == "detected" for p in after["points"])


def test_reach_limits_the_side_without_an_anchor():
    after = move_anchor(grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5]), 960, 0.6, reach=1920)
    # À direita, só até o ponto a dois tempos (2880, 1,5 s), que fica; à esquerda não há ponto tão longe: anda junto.
    assert times(after) == [0.1, 0.6, 1.05, 1.5, 2.0, 2.5]  # 1 s estava no meio de 0,5–1,5; fica no meio de 0,6–1,5
