"""O ajuste fino da batida: levar uma batida a um segundo mexe só até as âncoras vizinhas."""

import pytest

from tracklab.tempomap import (RhythmError, anchor_edit, double_beats, halve_beats, map_of, move_anchor,
                               release_anchor, tap_beats)


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


def test_taps_rewrite_the_beats_they_cover():
    before = grid([0.5 * k for k in range(24)], anchors=(6,))
    taps = [2.04, 2.53, 3.07, 3.55, 4.06]  # um pouco atrasados e tremidos, a partir da batida de 2 s
    after = tap_beats(before, taps, reach=4 * 960)
    tapped = after["points"][4:9]
    assert [p["seconds"] for p in tapped] == taps
    assert [p["kind"] for p in tapped] == ["anchor", "detected", "detected", "detected", "anchor"]
    # A âncora de dentro do trecho (3 s) deu lugar ao toque; fora do alcance nada mexe.
    assert times(after)[:1] == [0.0] and times(after)[13:] == [0.5 * k for k in range(13, 24)]
    # Entre o trecho e o alcance, as batidas acompanham sem passar umas pelas outras.
    assert all(b > a for a, b in zip(times(after), times(after)[1:]))


def test_taps_go_through_the_gesture_and_need_order_and_enough_of_them():
    before = grid([0.5 * k for k in range(24)])
    after = anchor_edit({"tempoMap": before, "action": "tap", "taps": [1.0, 1.52, 2.0, 2.49]})
    assert times(after)[2:6] == [1.0, 1.52, 2.0, 2.49]
    with pytest.raises(RhythmError, match="4 vezes"):
        tap_beats(before, [1.0, 1.5, 2.0])
    with pytest.raises(RhythmError, match="ordem"):
        tap_beats(before, [1.0, 1.5, 1.45, 2.0])
    with pytest.raises(RhythmError, match="toques"):
        anchor_edit({"tempoMap": before, "action": "tap"})


def test_double_and_half_change_the_beats_not_the_time():
    bars = {"schemaVersion": 1, "source": "reference", "points": [
        {"tick": 960 * k, "seconds": 0.5 * k, "kind": "detected" if k % 4 == 0 else "interpolated"} for k in range(9)]}
    doubled = double_beats(bars)
    assert [p["tick"] for p in doubled["points"]] == [480 * k for k in range(17)]
    assert all(map_of(doubled).seconds(t) == map_of(bars).seconds(t) for t in range(0, 7681, 240))
    halved = halve_beats(bars)
    # De cada início de compasso, sai uma interpolada a cada duas: ficam o 1 e o 3.
    assert [p["tick"] for p in halved["points"]] == [0, 1920, 3840, 5760, 7680]
    assert halve_beats(doubled)["points"] == bars["points"]
    # Âncoras e toques ficam, mesmo fora do passo.
    anchored = move_anchor(bars, 960, 0.55)
    assert 960 in [p["tick"] for p in halve_beats(anchored)["points"]]
    assert anchor_edit({"tempoMap": bars, "action": "double"}) == doubled
