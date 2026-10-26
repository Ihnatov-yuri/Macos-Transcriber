#!/usr/bin/env python3
"""Convert WeSpeaker's SimAM-ResNet100 (VoxBlink2 pretrain + VoxCeleb ft)
to the CoreML model Transcriberr downloads for Settings > People > Voice
model.

The model takes 298 frames x 80 Kaldi fbanks (3 s at 16 kHz, CMN per
window) and returns a 256-d embedding. The fbanks are computed in Swift
(KaldiFbank.swift); this script also writes reference waveforms (synthetic,
from a fixed seed), fbanks and embeddings that the Swift tests compare
against. Real meeting clips are used only to check the conversion and are
never written out.

Weights: https://github.com/wenet-e2e/wespeaker (docs/pretrained.md),
voxblink2_samresnet100_ft.zip. Licence CC BY-NC-SA 4.0 (VoxBlink2).

Usage: convert_simam.py <avg_model.pt> <speaker-clips dir> <out dir>
       convert_simam.py --reference <avg_model.pt> <out dir>
"""
import importlib
import sys
import types
import wave
from pathlib import Path

import numpy as np
import torch
import torchaudio.compliance.kaldi as kaldi

FRAMES = 298          # 3 s: 1 + (48000 - 400) // 160
SAMPLES = 48_000


def simam100():
    """WeSpeaker's SimAM module without the package __init__ (which pulls
    in s3prl and friends)."""
    site = Path(importlib.util.find_spec("torch").origin).parents[1] / "wespeaker"
    for pkg, path in (("wespeaker", site), ("wespeaker.models", site / "models")):
        if pkg not in sys.modules:
            mod = types.ModuleType(pkg)
            mod.__path__ = [str(path)]
            sys.modules[pkg] = mod
    sam = importlib.import_module("wespeaker.models.samresnet")
    return sam.SimAM_ResNet100_ASP(in_planes=64, embed_dim=256, acoustic_dim=80)


def fbank(wav):
    """WeSpeaker's front end, exactly: 80 Kaldi fbanks on 16-bit-scaled
    samples, CMN over the window."""
    x = torch.from_numpy(wav).float().unsqueeze(0) * (1 << 15)
    f = kaldi.fbank(x, num_mel_bins=80, frame_length=25, frame_shift=10, dither=0.0,
                    sample_frequency=16000, window_type="hamming", energy_floor=0.0)
    return f - f.mean(0, keepdim=True)


def read_wav(path):
    with wave.open(str(path)) as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768


def main():
    if sys.argv[1] == "--reference":   # convert_simam.py --reference <avg_model.pt> <out dir>
        net = simam100()
        state = torch.load(sys.argv[2], map_location="cpu", weights_only=True)
        net.load_state_dict({k: v for k, v in state.items() if not k.startswith("projection")}, strict=False)
        write_reference(net.eval(), Path(sys.argv[3]))
        return
    ckpt, clips_dir, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    net = simam100()
    state = torch.load(ckpt, map_location="cpu", weights_only=True)
    missing, unexpected = net.load_state_dict({k: v for k, v in state.items() if not k.startswith("projection")}, strict=False)
    assert not missing, missing
    net.eval()

    wavs = [read_wav(p) for p in sorted((clips_dir / "clips").glob("*.wav"))[::9]]
    wavs = [w for w in wavs if len(w) >= SAMPLES]
    windows = [w[(len(w) - SAMPLES) // 2:][:SAMPLES] for w in wavs]
    feats = [fbank(w) for w in windows]
    assert all(f.shape == (FRAMES, 80) for f in feats)

    import coremltools as ct
    with torch.no_grad():
        traced = torch.jit.trace(net, feats[0][None])
        ref = [net(f[None])[0].numpy() for f in feats]
    ml = ct.convert(traced, inputs=[ct.TensorType(name="feats", shape=(1, FRAMES, 80))],
                    outputs=[ct.TensorType(name="embedding")],
                    convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                    compute_units=ct.ComputeUnit.ALL, minimum_deployment_target=ct.target.macOS14)
    ml.short_description = ("SimAM-ResNet100 speaker embedding (WeSpeaker, VoxBlink2 + VoxCeleb ft). "
                            "Input: 298x80 Kaldi fbank (3 s, CMN). Licence CC BY-NC-SA 4.0.")
    ml.author = "WeSpeaker (wenet-e2e); CoreML conversion for Transcriberr"
    ml.license = "CC BY-NC-SA 4.0"
    pkg = out / "SimAMResNet100.mlpackage"
    ml.save(str(pkg))
    got = [ml.predict({"feats": f[None].numpy().astype(np.float32)})["embedding"].reshape(-1) for f in feats]
    cos = [float(a @ b / np.linalg.norm(a) / np.linalg.norm(b)) for a, b in zip(ref, got)]
    print(f"{len(cos)} windows: CoreML vs PyTorch cosine min {min(cos):.4f} mean {np.mean(cos):.4f}")

    write_reference(net, out / "reference")
    print("wrote", pkg)


def synthetic_voices():
    """Three 3 s voice-like signals from a fixed seed: a glottal pulse
    train at a wandering pitch through moving formants, plus noise. The
    Swift tests compare against these, never against anyone's speech."""
    rng = np.random.default_rng(20261024)
    t = np.arange(SAMPLES) / 16000
    out = []
    for f0, formants in ((115, (700, 1200, 2600)), (210, (850, 1700, 2900)), (160, (400, 2000, 2800))):
        pitch = f0 * (1 + 0.08 * np.sin(2 * np.pi * 0.7 * t) + 0.02 * rng.standard_normal(SAMPLES).cumsum() / 400)
        phase = 2 * np.pi * np.cumsum(pitch) / 16000
        source = np.sign(np.sin(phase)) * (np.sin(phase) ** 2)
        voice = np.zeros(SAMPLES)
        for i, f in enumerate(formants):
            fm = f * (1 + 0.1 * np.sin(2 * np.pi * (0.4 + 0.3 * i) * t))
            voice += np.sin(2 * np.pi * np.cumsum(fm) / 16000) * source / (i + 1)
        envelope = 0.5 + 0.5 * np.sin(2 * np.pi * 3.1 * t) ** 2
        out.append((0.2 * voice * envelope + 0.01 * rng.standard_normal(SAMPLES)).astype(np.float32))
    return out


def write_reference(net, ref_dir):
    """References for TranscriberrTests/KaldiFbankTests: the synthetic
    waves, their fbanks, and the PyTorch embeddings."""
    ref_dir.mkdir(parents=True, exist_ok=True)
    waves = synthetic_voices()
    feats = [fbank(w) for w in waves]
    with torch.no_grad():
        embs = [net(f[None])[0].numpy() for f in feats]
    np.stack(waves).astype("<f4").tofile(ref_dir / "waves.f32")
    np.stack([f.numpy() for f in feats]).astype("<f4").tofile(ref_dir / "fbanks.f32")
    np.stack(embs).astype("<f4").tofile(ref_dir / "embeddings.f32")
    print("wrote", ref_dir)


if __name__ == "__main__":
    main()
