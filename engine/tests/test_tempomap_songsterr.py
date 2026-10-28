"""O mapa inicial a partir dos pontos de sincronização do Songsterr: um ponto por compasso, batidas por dentro."""

import pytest

from tracklab.tempomap import RhythmError, beat_ticks, from_bar_starts, map_of


def test_bar_starts_become_detected_points_and_beats_are_interpolated():
    tempo = from_bar_starts([1.0, 3.0, 5.0], [(4, 4), (4, 4)])
    points = tempo["points"]
    assert tempo["source"] == "reference" and tempo["algorithm"] == "songsterr-video-points"
    assert [p["tick"] for p in points] == [960 * k for k in range(9)]
    assert [p["kind"] for p in points[::4]] == ["detected", "detected", "detected"]
    assert points[1] == {"tick": 960, "seconds": 1.5, "kind": "interpolated"}
    assert map_of(tempo).seconds(4800) == pytest.approx(3.5)


def test_without_the_closing_point_the_last_bar_keeps_the_previous_tempo():
    tempo = from_bar_starts([0.5, 2.5], [(4, 4), (4, 4)])
    last = tempo["points"][-1]
    assert last == {"tick": 7680, "seconds": 4.5, "kind": "interpolated"}


def test_signature_changes_and_compound_meter_beats():
    assert beat_ticks(6, 8) == 1440 and beat_ticks(3, 8) == 480 and beat_ticks(2, 2) == 1920
    tempo = from_bar_starts([0.0, 1.5, 3.0, 4.0], [(3, 4), (6, 8), (2, 4)])
    ticks = [p["tick"] for p in tempo["points"]]
    # 3/4: 0, 960, 1920; 6/8: 2880, 4320; 2/4: 5760, 6720; fim 7680
    assert ticks == [0, 960, 1920, 2880, 4320, 5760, 6720, 7680]


def test_extra_points_are_ignored_and_bad_points_refused():
    assert len(from_bar_starts([0, 2, 4, 6, 8], [(4, 4)])["points"]) == 5
    with pytest.raises(RhythmError):
        from_bar_starts([0.0, 2.0, 1.0], [(4, 4), (4, 4)])
    with pytest.raises(RhythmError):
        from_bar_starts([0.0], [(4, 4), (4, 4)])
    with pytest.raises(RhythmError):
        from_bar_starts([0.0], [(4, 4)])
