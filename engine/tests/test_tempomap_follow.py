"""Alinhar pela referência: as batidas vão aos ataques casados, batida a batida, e as âncoras da pessoa ficam."""

import pytest

from tracklab.tempomap import follow_anchors, map_of


def grid(count: int, start: float = 1.0, step: float = 0.5, anchors: tuple[int, ...] = ()) -> dict:
    return {"schemaVersion": 1, "source": "audio",
            "points": [{"tick": 960 * k, "seconds": start + step * k, "kind": "anchor" if k in anchors else "detected"}
                       for k in range(count)]}


def heard(tick: float) -> float:
    """A banda acelera: começa a 0,5 s por batida e encurta 2 ms a cada batida."""
    beat = tick / 960
    return 1.0 + 0.5 * beat - 0.001 * beat * beat


def test_beats_follow_the_matched_attacks_through_a_drift():
    pairs = [(480.0 * k, heard(480.0 * k)) for k in range(0, 80)]  # colcheias casadas na música toda
    followed, report = follow_anchors(grid(40), pairs)
    converter = map_of(followed)
    assert report["beats"] >= 38
    for beat in (4, 16, 24, 36):
        assert converter.seconds(960 * beat) == pytest.approx(heard(960 * beat), abs=0.01)
    assert followed["source"] == "reference"


def test_a_wrong_match_does_not_pull_the_grid():
    pairs = [(480.0 * k, 1.0 + 0.25 * k) for k in range(0, 40)]
    pairs[20] = (pairs[20][0], pairs[20][1] + 0.3)  # um ataque casado com a nota errada
    followed, _ = follow_anchors(grid(20), pairs)
    assert map_of(followed).seconds(960 * 10) == pytest.approx(6.0, abs=0.005)


def test_anchors_stay_and_the_bar_around_them_goes_with_them():
    pairs = [(480.0 * k, 1.2 + 0.25 * k) for k in range(0, 80)]  # tudo 200 ms depois da grade
    followed, report = follow_anchors(grid(40, anchors=(20,)), pairs)
    points = {p["tick"]: p for p in followed["points"]}
    assert points[960 * 20]["seconds"] == 11.0 and points[960 * 20]["kind"] == "anchor"
    assert points[960 * 4]["seconds"] == pytest.approx(3.2) and points[960 * 30]["seconds"] == pytest.approx(16.2)
    # Perto da âncora, as batidas se re-espaçam entre ela e as apoiadas.
    seconds = [p["seconds"] for p in followed["points"]]
    assert all(b > a for a, b in zip(seconds, seconds[1:]))


def test_without_support_the_map_stays_and_unsupported_stretches_are_interpolated():
    untouched, report = follow_anchors(grid(10), [(0.0, 1.0)])
    assert report["beats"] == 0 and [p["seconds"] for p in untouched["points"]] == [1.0 + 0.5 * k for k in range(10)]
    # Ataques só no começo e no fim: o meio se re-espaça entre eles e fica fraco.
    pairs = [(480.0 * k, 1.1 + 0.25 * k) for k in range(0, 10)] + [(480.0 * k, 1.3 + 0.25 * k) for k in range(60, 80)]
    followed, _ = follow_anchors(grid(40), pairs)
    middle = next(p for p in followed["points"] if p["tick"] == 960 * 18)
    assert middle["kind"] == "interpolated" and middle["confidence"] < 0.5
    assert 1.1 + 0.5 * 18 < middle["seconds"] < 1.3 + 0.5 * 18


def test_heard_beats_within_reach_win_the_phase_and_anchors_stay():
    from tracklab.tempomap import snap_to_pulse

    fitted = grid(8, start=1.03, anchors=(4,))  # as notas puseram tudo 30 ms depois do pulso
    heard = [1.0 + 0.5 * k for k in range(8)]
    heard[6] = 4.2  # uma batida ouvida longe (200 ms): não vale
    snapped, count = snap_to_pulse(fitted, heard)
    seconds = [round(p["seconds"], 6) for p in snapped["points"]]
    assert seconds == [1.0, 1.5, 2.0, 2.5, 3.03, 3.5, 4.03, 4.5] and count == 6
    assert next(p for p in snapped["points"] if p["tick"] == 960 * 4)["kind"] == "anchor"
    same, none = snap_to_pulse(fitted, [])
    assert none == 0 and [p["seconds"] for p in same["points"]] == [p["seconds"] for p in fitted["points"]]
