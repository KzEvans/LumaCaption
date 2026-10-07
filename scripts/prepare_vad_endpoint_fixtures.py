#!/usr/bin/env python3
"""Create silent-test fixtures from the complete public whisper.cpp JFK sample.

Gap cases are synthetic replays of complete samples, not continuous speeches.
No sound is played. Generated PCM belongs under ignored build/, never source.
"""

import argparse
import hashlib
import json
from pathlib import Path
import wave


ROOT = Path(__file__).resolve().parent.parent
JFK_SHA256 = "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e"
EXPECTED = (
    "And so my fellow Americans ask not what your country can do for you "
    "ask what you can do for your country"
)


def write_wav(path, pcm):
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes(pcm)


def prepare(source, output_directory):
    source_bytes = source.read_bytes()
    if hashlib.sha256(source_bytes).hexdigest() != JFK_SHA256:
        raise ValueError("Source must be the pinned complete public JFK WAV")
    with wave.open(str(source), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (
            1, 2, 16000
        ):
            raise ValueError("Expected mono 16-bit 16 kHz JFK sample")
        pcm = audio.readframes(audio.getnframes())
    zero = lambda milliseconds: bytes(16000 * milliseconds // 1000 * 2)
    fixtures = [
        (
            "long-gap", pcm + zero(1200) + pcm, EXPECTED + " " + EXPECTED,
            "Complete JFK sample, 1200 ms inserted digital silence, complete JFK replay",
            [{"startMs": 11000, "endMs": 12200}], True,
        ),
        (
            "short-gap", pcm + zero(200) + pcm, EXPECTED + " " + EXPECTED,
            "Complete JFK sample, 200 ms inserted digital silence, complete JFK replay",
            [{"startMs": 11000, "endMs": 11200}], True,
        ),
        (
            "sustained-over-8s", pcm + zero(1200), EXPECTED,
            "Complete 11 s JFK sample, followed by 1200 ms digital silence",
            [{"startMs": 11000, "endMs": 12200}], True,
        ),
        (
            "real-eof", pcm, EXPECTED,
            "Unmodified complete 11 s JFK PCM; EOF is not padded with silence",
            [], False,
        ),
    ]
    output_directory.mkdir(parents=True, exist_ok=True)
    records = []
    for fixture_id, fixture_pcm, expected, description, gaps, synthetic in fixtures:
        path = output_directory / (fixture_id + ".wav")
        write_wav(path, fixture_pcm)
        records.append({
            "id": fixture_id,
            "file": path.name,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "pcmSha256": hashlib.sha256(fixture_pcm).hexdigest(),
            "samples": len(fixture_pcm) // 2,
            "durationMs": len(fixture_pcm) // 2 * 1000 / 16000,
            "description": description,
            "syntheticReplayOrPadding": synthetic,
            "insertedSilence": gaps,
            "expectedText": expected,
            "expectedWords": len(expected.split()),
        })
    metadata = {
        "schemaVersion": 1,
        "source": "https://github.com/ggml-org/whisper.cpp/blob/v1.8.1/samples/jfk.wav",
        "sourceSha256": JFK_SHA256,
        "sourcePcmSha256": hashlib.sha256(pcm).hexdigest(),
        "sampleRate": 16000,
        "channels": 1,
        "sourceSamples": len(pcm) // 2,
        "fixtures": records,
        "limitations": [
            "One clean public English sample; not a representative speech corpus",
            "Inserted digital silence differs from environmental quiet or music",
            "Gap fixtures replay a complete sample, not a continuous real speech",
        ],
    }
    manifest = output_directory / "manifest.json"
    manifest.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    return manifest.resolve()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / ".tools/whisper.cpp/samples/jfk.wav")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/vad-endpoint-fixtures")
    args = parser.parse_args()
    print(prepare(args.source, args.output_dir))


if __name__ == "__main__":
    main()
