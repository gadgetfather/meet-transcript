#!/usr/bin/env python3
import argparse
import json
import os
import sys
from faster_whisper import WhisperModel


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--model", default="small.en")
    parser.add_argument("--language", default="en")
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--compute-type", default="int8")
    parser.add_argument("--beam-size", type=int, default=5)
    parser.add_argument("--no-vad", action="store_true")
    args = parser.parse_args()

    audio_path = os.path.abspath(args.audio)
    if not os.path.exists(audio_path):
        print(json.dumps({"error": f"audio file not found: {audio_path}"}))
        return 2

    try:
        model = WhisperModel(args.model, device=args.device, compute_type=args.compute_type)
        segments, info = model.transcribe(
            audio_path,
            language=args.language,
            beam_size=args.beam_size,
            vad_filter=not args.no_vad,
            word_timestamps=True,
        )

        out_segments = []
        texts = []
        for seg in segments:
            text = (seg.text or "").strip()
            if not text:
                continue
            texts.append(text)
            words = []
            for word in (getattr(seg, "words", None) or []):
                raw_word = word.word or ""
                if not raw_word.strip():
                    continue
                word_start = float(word.start) if word.start is not None else float(seg.start)
                word_end = float(word.end) if word.end is not None else float(seg.end)
                words.append(
                    {
                        "start": word_start,
                        "end": word_end,
                        "word": raw_word,
                    }
                )

            out_segments.append(
                {
                    "start": float(seg.start),
                    "end": float(seg.end),
                    "text": text,
                    "words": words,
                }
            )

        payload = {
            "text": " ".join(texts).strip(),
            "segments": out_segments,
            "language": info.language,
            "language_probability": float(info.language_probability),
        }
        print(json.dumps(payload, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
