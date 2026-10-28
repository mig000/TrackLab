"""O mapa de batida do TabLab: tique ↔ segundo por trechos e o contrato conferido."""

import pytest

from tracklab.tempomap import RhythmError, TempoMap, normalize_tempo_map


def test_conversion_is_piecewise_and_extrapolates_from_the_ends():
    converter = TempoMap([(0, 1.0), (960, 1.5), (1920, 2.5)])
    assert converter.seconds(480) == pytest.approx(1.25)
    assert converter.seconds(1440) == pytest.approx(2.0)
    assert converter.tick(2.0) == pytest.approx(1440)
    assert converter.seconds(-960) == pytest.approx(0.5)
    assert converter.seconds(2880) == pytest.approx(3.5)
    assert converter.tick(converter.seconds(1234.5)) == pytest.approx(1234.5)

@pytest.mark.parametrize("raw, words", [
    ({"points": [{"tick": 0, "seconds": 0}]}, "de 2 a"),
    ({"points": [{"tick": 0, "seconds": 1.0}, {"tick": 960, "seconds": 0.5}]}, "crescer juntos"),
    ({"points": [{"tick": 0, "seconds": 0}, {"tick": 960, "seconds": 0.01}]}, "10 a 1000 BPM"),
    ({"points": [{"tick": 0, "seconds": 0, "kind": "guess"}, {"tick": 960, "seconds": 0.5}]}, "kind"),
    ({"points": [{"tick": 0, "seconds": 0}, {"tick": 960, "seconds": 0.5}], "source": "magic"}, "source"),
    ({"points": "0,0"}, "points"),
    ([], "objeto"),
])
def test_invalid_maps_are_refused(raw, words):
    with pytest.raises(RhythmError, match=words):
        normalize_tempo_map(raw)

def test_normalized_map_is_sorted_and_keeps_kinds_and_confidence():
    raw = {"source": "audio", "algorithm": "beats-py-1", "points": [
        {"tick": 960, "seconds": 0.9, "kind": "anchor"},
        {"tick": 0, "seconds": 0.4, "confidence": 1.7},
    ]}
    clean = normalize_tempo_map(raw)
    assert [p["tick"] for p in clean["points"]] == [0, 960]
    assert clean["points"][0] == {"tick": 0, "seconds": 0.4, "kind": "detected", "confidence": 1.0}
    assert clean["points"][1]["kind"] == "anchor"
    assert clean["algorithm"] == "beats-py-1" and clean["schemaVersion"] == 1
