#!/usr/bin/env python3
import argparse
import json
import os
import sys
from dataclasses import dataclass
from typing import Dict, List, Tuple

import av
import numpy as np


@dataclass
class SpeechRegion:
    start: float
    end: float
    embedding: np.ndarray
    label: int = 0


def hz_to_mel(hz: np.ndarray) -> np.ndarray:
    return 2595.0 * np.log10(1.0 + hz / 700.0)


def mel_to_hz(mel: np.ndarray) -> np.ndarray:
    return 700.0 * (10.0 ** (mel / 2595.0) - 1.0)


def build_mel_filterbank(
    sample_rate: int,
    n_fft: int,
    n_mels: int = 24,
    f_min: float = 80.0,
    f_max: float = 7600.0,
) -> np.ndarray:
    f_max = min(f_max, sample_rate / 2.0 - 1.0)
    mel_min = hz_to_mel(np.array([f_min], dtype=np.float32))[0]
    mel_max = hz_to_mel(np.array([f_max], dtype=np.float32))[0]
    mel_points = np.linspace(mel_min, mel_max, n_mels + 2, dtype=np.float32)
    hz_points = mel_to_hz(mel_points)
    bins = np.floor((n_fft + 1) * hz_points / sample_rate).astype(np.int32)
    bins = np.clip(bins, 0, n_fft // 2)

    fb = np.zeros((n_mels, n_fft // 2 + 1), dtype=np.float32)
    for m in range(1, n_mels + 1):
        left = bins[m - 1]
        center = bins[m]
        right = bins[m + 1]
        if center <= left:
            center = left + 1
        if right <= center:
            right = center + 1
        right = min(right, n_fft // 2)

        for k in range(left, center):
            fb[m - 1, k] = (k - left) / float(center - left)
        for k in range(center, right):
            fb[m - 1, k] = (right - k) / float(right - center)

    return fb


def build_dct_matrix(n_mels: int, n_mfcc: int) -> np.ndarray:
    n = np.arange(n_mels, dtype=np.float32)
    dct = np.zeros((n_mfcc, n_mels), dtype=np.float32)
    dct[0] = np.sqrt(1.0 / n_mels)
    for k in range(1, n_mfcc):
        dct[k] = np.sqrt(2.0 / n_mels) * np.cos(np.pi * k * (2.0 * n + 1.0) / (2.0 * n_mels))
    return dct


def frame_audio(audio: np.ndarray, frame_size: int, hop_size: int) -> np.ndarray:
    if audio.size == 0:
        return np.zeros((0, frame_size), dtype=np.float32)

    if audio.size < frame_size:
        pad = frame_size - audio.size
        audio = np.pad(audio, (0, pad))

    frame_count = 1 + (audio.size - frame_size) // hop_size
    shape = (frame_count, frame_size)
    strides = (audio.strides[0] * hop_size, audio.strides[0])
    return np.lib.stride_tricks.as_strided(audio, shape=shape, strides=strides).copy()


def load_audio_mono_16k(audio_path: str) -> Tuple[np.ndarray, int]:
    container = av.open(audio_path)
    stream = next((s for s in container.streams if s.type == "audio"), None)
    if stream is None:
        return np.zeros(0, dtype=np.float32), 16000

    resampler = av.audio.resampler.AudioResampler(format="fltp", layout="mono", rate=16000)
    chunks: List[np.ndarray] = []

    for frame in container.decode(stream):
        resampled = resampler.resample(frame)
        if not resampled:
            continue
        for out in resampled:
            arr = out.to_ndarray().astype(np.float32).reshape(-1)
            if arr.size:
                chunks.append(arr)

    flushed = resampler.resample(None)
    if flushed:
        for out in flushed:
            arr = out.to_ndarray().astype(np.float32).reshape(-1)
            if arr.size:
                chunks.append(arr)

    if not chunks:
        return np.zeros(0, dtype=np.float32), 16000

    audio = np.concatenate(chunks).astype(np.float32)
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    if peak > 1e-6:
        audio = audio / peak
    return audio, 16000


def detect_speech_regions(audio: np.ndarray, sr: int) -> List[Tuple[float, float]]:
    frame_size = int(0.03 * sr)
    hop_size = int(0.01 * sr)
    frames = frame_audio(audio, frame_size, hop_size)
    if frames.shape[0] == 0:
        return []

    rms = np.sqrt(np.mean(frames * frames, axis=1) + 1e-10)
    noise_floor = float(np.percentile(rms, 20))
    threshold = max(noise_floor * 2.2, 0.015)
    speech_mask = rms > threshold

    # Fill short holes in speech activity to avoid excessive fragmentation.
    hole = int(0.12 / (hop_size / sr))
    if hole > 0 and speech_mask.size > 2 * hole:
        fixed = speech_mask.copy()
        for i in range(hole, speech_mask.size - hole):
            if not speech_mask[i] and np.all(speech_mask[i - hole : i]) and np.all(speech_mask[i + 1 : i + 1 + hole]):
                fixed[i] = True
        speech_mask = fixed

    regions: List[Tuple[float, float]] = []
    start = None
    for i, active in enumerate(speech_mask):
        if active and start is None:
            start = i
        elif not active and start is not None:
            end = i - 1
            s = start * hop_size / sr
            e = end * hop_size / sr + frame_size / sr
            regions.append((s, e))
            start = None

    if start is not None:
        end = speech_mask.size - 1
        s = start * hop_size / sr
        e = end * hop_size / sr + frame_size / sr
        regions.append((s, e))

    # Merge short gaps and remove tiny fragments.
    merged: List[Tuple[float, float]] = []
    min_duration = 0.65
    max_gap = 0.35

    for s, e in regions:
        if e - s < min_duration:
            continue
        if not merged:
            merged.append((s, e))
            continue
        prev_s, prev_e = merged[-1]
        if s - prev_e <= max_gap:
            merged[-1] = (prev_s, e)
        else:
            merged.append((s, e))

    return merged


def extract_embedding(
    audio: np.ndarray,
    sr: int,
    start_s: float,
    end_s: float,
    mel_fb: np.ndarray,
    dct: np.ndarray,
) -> np.ndarray:
    s = max(0, int(start_s * sr))
    e = min(audio.size, int(end_s * sr))
    chunk = audio[s:e]
    if chunk.size < int(0.4 * sr):
        return np.zeros(30, dtype=np.float32)

    frame_size = int(0.025 * sr)
    hop_size = int(0.01 * sr)
    frames = frame_audio(chunk, frame_size, hop_size)
    if frames.shape[0] < 2:
        return np.zeros(30, dtype=np.float32)

    frames = frames * np.hanning(frame_size).astype(np.float32)
    n_fft = 512
    spectrum = np.fft.rfft(frames, n=n_fft, axis=1)
    power = (np.abs(spectrum) ** 2) / n_fft

    mel = np.maximum(power @ mel_fb.T, 1e-10)
    log_mel = np.log(mel)
    mfcc = log_mel @ dct.T
    mfcc = mfcc - np.mean(mfcc, axis=0, keepdims=True)

    freqs = np.fft.rfftfreq(n_fft, d=1.0 / sr)
    mag = np.abs(spectrum)
    centroid = np.sum(mag * freqs, axis=1) / (np.sum(mag, axis=1) + 1e-10)

    feature = np.concatenate(
        [
            np.mean(mfcc, axis=0),
            np.std(mfcc, axis=0),
            np.array(
                [
                    float(np.mean(centroid) / 4000.0),
                    float(np.std(centroid) / 2000.0),
                    float(end_s - start_s),
                    float(np.mean(np.sqrt(np.mean(frames * frames, axis=1)))),
                ],
                dtype=np.float32,
            ),
        ]
    ).astype(np.float32)

    norm = float(np.linalg.norm(feature))
    if norm > 1e-8:
        feature = feature / norm
    return feature


def pairwise_distances(x: np.ndarray) -> np.ndarray:
    sq = np.sum(x * x, axis=1, keepdims=True)
    d2 = np.maximum(sq + sq.T - 2.0 * (x @ x.T), 0.0)
    return np.sqrt(d2)


def kmeans_pp_init(x: np.ndarray, k: int, rng: np.random.Generator) -> np.ndarray:
    n = x.shape[0]
    centers = np.zeros((k, x.shape[1]), dtype=np.float32)
    idx = int(rng.integers(0, n))
    centers[0] = x[idx]
    closest_dist_sq = np.sum((x - centers[0]) ** 2, axis=1)
    for c in range(1, k):
        total = float(np.sum(closest_dist_sq))
        if total <= 1e-12 or not np.isfinite(total):
            idx = int(rng.integers(0, n))
        else:
            probs = closest_dist_sq / total
            probs = np.clip(probs, 0.0, 1.0)
            probs_sum = float(np.sum(probs))
            if probs_sum <= 1e-12:
                idx = int(rng.integers(0, n))
            else:
                probs = probs / probs_sum
                idx = int(rng.choice(n, p=probs))
        centers[c] = x[idx]
        new_dist_sq = np.sum((x - centers[c]) ** 2, axis=1)
        closest_dist_sq = np.minimum(closest_dist_sq, new_dist_sq)
    return centers


def run_kmeans(x: np.ndarray, k: int, seed: int = 7, max_iter: int = 60) -> Tuple[np.ndarray, np.ndarray, float]:
    rng = np.random.default_rng(seed)
    centers = kmeans_pp_init(x, k, rng)

    labels = np.zeros(x.shape[0], dtype=np.int32)
    for _ in range(max_iter):
        d = pairwise_distances(np.vstack([x, centers]))
        dist = d[: x.shape[0], x.shape[0] :]
        new_labels = np.argmin(dist, axis=1).astype(np.int32)
        if np.array_equal(new_labels, labels):
            break
        labels = new_labels

        for j in range(k):
            members = x[labels == j]
            if members.shape[0] == 0:
                farthest = np.argmax(np.min(dist, axis=1))
                centers[j] = x[farthest]
            else:
                centers[j] = np.mean(members, axis=0)

    final_dist = np.linalg.norm(x - centers[labels], axis=1)
    inertia = float(np.sum(final_dist ** 2))
    return labels, centers, inertia


def silhouette_score(x: np.ndarray, labels: np.ndarray) -> float:
    n = x.shape[0]
    uniq = np.unique(labels)
    if uniq.size <= 1 or uniq.size >= n:
        return -1.0

    d = pairwise_distances(x)
    scores = []
    for i in range(n):
        same = labels == labels[i]
        same_count = int(np.sum(same))
        if same_count <= 1:
            a = 0.0
        else:
            a = float(np.sum(d[i, same]) / (same_count - 1))

        b = float("inf")
        for c in uniq:
            if c == labels[i]:
                continue
            other = labels == c
            if not np.any(other):
                continue
            b = min(b, float(np.mean(d[i, other])))

        denom = max(a, b)
        if not np.isfinite(denom) or denom <= 1e-12:
            scores.append(0.0)
        else:
            scores.append((b - a) / denom)

    return float(np.mean(scores)) if scores else -1.0


def choose_speaker_count(x: np.ndarray, min_speakers: int, max_speakers: int) -> int:
    n = x.shape[0]
    max_k = min(max_speakers, n)
    min_k = min(min_speakers, max_k)
    if n < 3 or max_k <= 1:
        return 1

    best_k = 1
    best_score = -1.0
    for k in range(max(2, min_k), max_k + 1):
        best_for_k = None
        best_inertia = float("inf")
        for seed in (7, 17, 31):
            labels, _, inertia = run_kmeans(x, k, seed=seed)
            if inertia < best_inertia:
                best_inertia = inertia
                best_for_k = labels

        if best_for_k is None:
            continue
        sil = silhouette_score(x, best_for_k)
        sil -= 0.02 * (k - 1)  # mild complexity penalty
        if sil > best_score:
            best_score = sil
            best_k = k

    if best_score < 0.10:
        return 1
    return max(1, best_k)


def diarize(audio_path: str, min_speakers: int, max_speakers: int) -> Dict[str, object]:
    audio, sr = load_audio_mono_16k(audio_path)
    if audio.size == 0:
        return {"segments": [], "num_speakers": 0}

    speech = detect_speech_regions(audio, sr)
    if not speech:
        return {"segments": [], "num_speakers": 0}

    mel_fb = build_mel_filterbank(sr, n_fft=512, n_mels=24)
    dct = build_dct_matrix(n_mels=24, n_mfcc=13)

    regions: List[SpeechRegion] = []
    for s, e in speech:
        emb = extract_embedding(audio, sr, s, e, mel_fb, dct)
        regions.append(SpeechRegion(start=s, end=e, embedding=emb))

    x = np.vstack([r.embedding for r in regions]) if regions else np.zeros((0, 30), dtype=np.float32)
    if x.shape[0] == 0:
        return {"segments": [], "num_speakers": 0}

    k = choose_speaker_count(x, min_speakers=min_speakers, max_speakers=max_speakers)
    if k <= 1:
        labels = np.zeros(x.shape[0], dtype=np.int32)
    else:
        best_labels = None
        best_inertia = float("inf")
        for seed in (7, 17, 31):
            labels_k, _, inertia = run_kmeans(x, k, seed=seed)
            if inertia < best_inertia:
                best_inertia = inertia
                best_labels = labels_k
        labels = best_labels if best_labels is not None else np.zeros(x.shape[0], dtype=np.int32)

    for i, r in enumerate(regions):
        r.label = int(labels[i])

    # Stabilize labels by re-ordering based on first appearance.
    label_first_seen = {}
    for r in regions:
        label_first_seen.setdefault(r.label, r.start)
    ordered = sorted(label_first_seen.keys(), key=lambda x: label_first_seen[x])
    label_to_name = {label: f"Participant {idx + 1}" for idx, label in enumerate(ordered)}

    merged = []
    max_merge_gap = 0.45
    for r in regions:
        speaker = label_to_name[r.label]
        if not merged:
            merged.append({"start": r.start, "end": r.end, "speaker": speaker})
            continue

        prev = merged[-1]
        if prev["speaker"] == speaker and r.start - prev["end"] <= max_merge_gap:
            prev["end"] = max(prev["end"], r.end)
        else:
            merged.append({"start": r.start, "end": r.end, "speaker": speaker})

    return {"segments": merged, "num_speakers": len(ordered)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--min-speakers", type=int, default=1)
    parser.add_argument("--max-speakers", type=int, default=4)
    args = parser.parse_args()

    audio_path = os.path.abspath(args.audio)
    if not os.path.exists(audio_path):
        print(json.dumps({"error": f"audio file not found: {audio_path}"}))
        return 2

    min_speakers = max(1, args.min_speakers)
    max_speakers = max(min_speakers, args.max_speakers)

    try:
        payload = diarize(audio_path, min_speakers=min_speakers, max_speakers=max_speakers)
        print(json.dumps(payload, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
