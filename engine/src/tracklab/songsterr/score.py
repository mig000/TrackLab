"""A partitura do Songsterr como GP: volumes por instrumento, armaduras, voz-guia muda e timbres.

Trazido do worker do BackingLab 2 (build 51), que já conferiu estas correções no Guitar Pro; o TrackLab só guarda
o GP sem áudio embutido, porque o tempo vem do mapa (`score/tempo-map.json`) e o áudio fica em `audio/`.
"""
from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile

VENDOR = Path(__file__).resolve().parent / "vendor"


def replace_zip(source: Path, target: Path, transform) -> None:
    with ZipFile(source) as a, ZipFile(target, 'w') as b:
        for info in a.infolist():
            data = a.read(info.filename)
            if info.filename == 'Content/score.gpif':
                data = transform(data)
            b.writestr(info, data)
    with ZipFile(target) as z:
        if z.testzip() is not None:
            raise ValueError('O arquivo gerado não passou na verificação de integridade.')
        ET.fromstring(z.read('Content/score.gpif'))


def desired_volume(track: dict) -> float:
    name = str(track.get('name', '')).lower()
    instrument = str(track.get('instrument', '')).lower()
    if any(s in name for s in ('handclap', 'hand clap', 'maraca', 'shaker', 'tambourine')):
        return .55
    if 'drum' in instrument or 'percussion' in instrument:
        return .68
    if 'bass' in instrument:
        return .74
    if any(s in instrument for s in ('piano', 'keyboard', 'organ')):
        return .61
    if 'guitar' in instrument:
        return .66 if 'lead guitar 2' in name else .69
    return .68


def vocal_guide(track: dict) -> bool:
    name = str(track.get('name', '')).lower()
    return any(s in name for s in ('vocal', 'voice', 'vocalist', 'singing'))


MASTER_RSE = b'''<RSE><Master>
<Effect id="M06_DynamicAnalogDynamic"><ByPass/><Parameters>0 0 0.8 0 0.4 0.6 0.5 0.5</Parameters></Effect>
<Effect id="M03_StudioReverbRoomStudioA"><ByPass/><Parameters>0 0 0 0 0</Parameters></Effect>
<Effect id="M08_GraphicEQ10Band"><ByPass/><Parameters>0 0 0.5 0.5 0.5 0.5 0.5 0.5 0.5 0.5 0.5 0.5 0.5</Parameters></Effect>
<Effect id="I01_VolumeAndPan"><Parameters>0.72 0.5</Parameters></Effect>
</Master></RSE>'''


def improve_score(data: bytes, tracks: list[dict], mute_vocals: bool) -> bytes:
    # Cada compasso recebe a armadura declarada pelo Songsterr, quando disponível.
    measures = tracks[0].get('measures', [])
    bar_block = re.search(rb'<MasterBars>.*?</MasterBars>', data, re.S)
    if not bar_block:
        raise ValueError('O conversor não gerou os compassos esperados.')
    current = None
    counter = 0
    def fix_bar(match):
        nonlocal current, counter
        if counter < len(measures) and measures[counter].get('keySignature'):
            current = measures[counter]['keySignature']
        counter += 1
        bar = match.group()
        if not current:
            return bar
        count = int(current.get('accidentalCount', 0))
        flat = str(current.get('transposeAs', '')).lower() in ('b', 'flat', 'flats')
        if flat and count > 0:
            count = -count
        if not -7 <= count <= 7:
            return bar
        mode = 'Minor' if str(current.get('mode', '')).lower() == 'minor' else 'Major'
        pref = 'Flats' if flat else 'Sharps'
        replacement = f'<Key><AccidentalCount>{count}</AccidentalCount><Mode>{mode}</Mode><TransposeAs>{pref}</TransposeAs></Key>'.encode()
        return re.sub(rb'<Key>.*?</Key>', lambda _: replacement, bar, count=1, flags=re.S)
    block = re.sub(rb'<MasterBar>.*?</MasterBar>', fix_bar, bar_block.group(), flags=re.S)
    data = data[:bar_block.start()] + block + data[bar_block.end():]

    m = re.search(rb'<Tracks>\s*<Track id=.*?</Tracks>', data, re.S)
    if not m:
        raise ValueError('O conversor não gerou as faixas esperadas.')
    def fix_track(match):
        track = match.group()
        ident = re.match(rb'<Track id="(\d+)">', track)
        i = int(ident.group(1))
        if i >= len(tracks):
            raise ValueError('Índice de faixa inesperado.')
        info = tracks[i]
        def levels(p):
            values = p.group(2).decode().split()
            if len(values) < 13:
                raise ValueError('Parâmetros de mix inesperados.')
            values[12] = f'{desired_volume(info):.2f}'
            return p.group(1) + ' '.join(values).encode() + p.group(3)
        track, changed = re.subn(rb'(<RSE>\s*<ChannelStrip[^>]*>\s*<Parameters>)([^<]+)(</Parameters>)', levels, track, count=1, flags=re.S)
        if changed != 1:
            raise ValueError(f'Não foi possível ajustar o volume da faixa {i + 1}.')
        if mute_vocals and vocal_guide(info):
            track, changed = re.subn(rb'(</MidiConnection>\s*<PlaybackState>)Default(</PlaybackState>)', rb'\1Mute\2', track, count=1)
            if changed != 1:
                raise ValueError(f'Não foi possível silenciar a voz da faixa {i + 1}.')
        # Reaproveita o timbre Blues escolhido no Guitar Pro para guitarras
        # rítmicas marcadas como jazz; mantém as mudanças para outros sons.
        if ('rhythm guitar' in str(info.get('name', '')).lower()
                and str(info.get('instrument', '')).lower() == 'electric guitar (jazz)'):
            sound = re.search(rb'<Sound>.*?</Sound>', track, re.S)
            if sound:
                parsed = ET.fromstring(sound.group())
                old = ';'.join(parsed.findtext(x) or '' for x in ('Path', 'Name', 'Role'))
                if old == 'Stringed/Electric Guitars/Jazz Guitar;Electric Guitar (jazz);User':
                    preset = (VENDOR / 'blues-rhythm-sound.xml').read_bytes()
                    track = track[:sound.start()] + preset + track[sound.end():]
                    track = track.replace(old.encode(),
                        b'Stringed/Electric Guitars/Overdrive Guitar;Blues;Factory')
        # O banco Rick-Bass já vem com o Guitar Pro; só aplicá-lo quando a fonte
        # identifica um Rickenbacker, sem trocar o instrumento de outros baixos.
        if 'rickenbacker' in str(info.get('name', '')).lower() and 'bass' in str(info.get('instrument', '')).lower():
            match_sound = re.search(rb'<Sound>.*?</Sound>', track, re.S)
            if match_sound and b'<RSE>' not in match_sound.group():
                rse = b'<RSE><SoundbankPatch>Rick-Bass</SoundbankPatch><ElementsSettings/><Pickups><OverloudPosition>0</OverloudPosition><Volumes>1 1</Volumes><Tones>1 1</Tones></Pickups><EffectChain><Effect id="A10_StackClassic"><Parameters>0.45 0 0 0.63 0.37 0.39 0.39 0.71</Parameters></Effect><Effect id="E31_EqBEq"><Parameters>0.657143 0.6 0.6 0.685714 0.342857 0.628571 0.714286 0.5</Parameters></Effect></EffectChain></RSE>'
                sound = match_sound.group().replace(b'</Sound>', rse + b'</Sound>', 1)
                track = track[:match_sound.start()] + sound + track[match_sound.end():]
        return track
    block = re.sub(rb'<Track id="\d+">.*?</Track>', fix_track, m.group(), flags=re.S)
    data = data[:m.start()] + block + data[m.end():]
    master = re.search(rb'<MasterTrack>.*?</MasterTrack>', data, re.S)
    if master and b'<RSE>' not in master.group():
        end = master.end() - len(b'</MasterTrack>')
        data = data[:end] + MASTER_RSE + data[end:]
    return data
