#!/usr/bin/env python3
"""Bounded release performance regression using generated, disposable inputs.

Example (one hour, ~636 MB generated PCM, deleted on completion):
  python3 scripts/performance_release_check.py --seconds 3600 \
    --output Validation/release-prep-20261024/performance-results.json

No original audio is read. /usr/bin/time measures fresh child processes, so RSS
includes the app/framework overhead but excludes fixture creation/Python. This
is CLI processing coverage, not a GUI responsiveness or cloud-I/O claim.
"""
import argparse
import array
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import wave

ROOT = Path(__file__).resolve().parents[1]


def fixture(path, seconds, rate=44100):
    # Integer-frequency, one-second repeated content: deterministic, bounded
    # generator memory and identical tonal/level statistics across lengths.
    block = array.array("h")
    for n in range(rate):
        t = n / rate
        left = 0.12 * math.sin(2 * math.pi * 83 * t) + 0.07 * math.sin(2 * math.pi * 997 * t)
        right = 0.11 * math.sin(2 * math.pi * 83 * t) + 0.06 * math.sin(2 * math.pi * 1009 * t)
        block.extend((round(32767 * left), round(32767 * right)))
    if sys.byteorder != "little":
        block.byteswap()
    with wave.open(str(path), "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(rate)
        raw = block.tobytes()
        for _ in range(seconds):
            out.writeframesraw(raw)


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def run_timed(app, arguments, output, timeout, expects_json=True):
    started = time.monotonic()
    with output.open("w") as stdout:
        proc = subprocess.Popen(["/usr/bin/time", "-l", str(app), *arguments],
                                stdout=stdout, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            _, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Stop only this runner's process group, including the app child.
            # Killing /usr/bin/time alone could leave the analysis running.
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            raise
    elapsed = time.monotonic() - started
    rss = re.search(r"(\d+)\s+maximum resident set size", stderr)
    cpu = re.search(r"([\d.]+)\s+real\s+([\d.]+)\s+user\s+([\d.]+)\s+sys", stderr)
    if proc.returncode:
        raise RuntimeError(f"Command failed ({proc.returncode}): {arguments}\n{stderr}")
    metrics = {"elapsedSeconds": elapsed, "peakRSSBytes": int(rss.group(1)) if rss else None}
    if cpu:
        metrics.update(userSeconds=float(cpu.group(2)), systemSeconds=float(cpu.group(3)))
    if metrics["peakRSSBytes"] is None:
        raise RuntimeError("macOS /usr/bin/time peak RSS could not be parsed")
    return json.loads(output.read_text()) if expects_json else None, metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/YA-MixCheck.app/Contents/MacOS/YA-MixCheck")
    parser.add_argument("--seconds", type=int, default=600)
    parser.add_argument("--baseline-seconds", type=int, default=60)
    parser.add_argument("--rate", type=int, choices=[44100,48000,88200,96000,176400,192000], default=44100)
    parser.add_argument("--timeout", type=int, default=900, help="Timeout per child process")
    parser.add_argument("--ffmpeg", help="Optional encoder for generated MP3 lifecycle test")
    parser.add_argument("--output", type=Path, default=ROOT / "Validation/release-prep-20261024/performance-results.json")
    args = parser.parse_args()
    if not 8 <= args.baseline_seconds < args.seconds <= 7200:
        parser.error("Require 8 <= baseline seconds < long seconds <= 7200")
    if sys.platform != "darwin":
        parser.error("This runner requires macOS /usr/bin/time -l and the macOS app")
    app = args.app.resolve()
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    pcm_bytes = args.seconds * args.rate * 4
    if pcm_bytes > 0xffffffff - 44:
        parser.error("Generated PCM exceeds WAV RIFF capacity; choose a shorter duration or lower rate")
    free = shutil.disk_usage(tempfile.gettempdir()).free
    if free < 2 * pcm_bytes + 2 * 1024 ** 3:
        parser.error("Insufficient free scratch space for source + snapshot with 2 GiB reserve")
    result = {"schema": 2, "sampleRate": args.rate, "initialFreeBytes": free, "appSHA256": sha(app),
              "host": {"macOS": platform.mac_ver()[0], "architecture": platform.machine()},
              "checks": [], "runs": [],
              "limitations": ["Synthetic periodic PCM; not music quality validation.",
                              "Cancellation latency starts at a processing progress callback, after opening/hashing the source.",
                              "No UI interaction, iCloud/network stall, source switching, app quit or forced-crash test.",
                              "Cache directory comparison requires no simultaneous GUI analyses/previews.",
                              "Feature arrays scale with duration; this test checks practical memory growth, not constant memory."]}

    def check(name, passed, detail=None):
        result["checks"].append({"name": name, "passed": bool(passed), "detail": detail})

    with tempfile.TemporaryDirectory(prefix="ya-performance-release-") as temp:
        scratch = Path(temp)
        baseline = scratch / "baseline.wav"
        long_file = scratch / "long.wav"
        for path, seconds in [(baseline, args.baseline_seconds), (long_file, args.seconds)]:
            fixture(path, seconds, rate=args.rate)
        ffmpeg = args.ffmpeg or shutil.which("ffmpeg")
        if not ffmpeg:
            try:
                import imageio_ffmpeg
                ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
            except ImportError:
                pass
        lifecycle_args = ["--performance-test"]
        if ffmpeg:
            mp3 = scratch / "generated.mp3"
            subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-i", str(baseline),
                            "-t", "12", "-codec:a", "libmp3lame", "-b:a", "192k", str(mp3)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60)
            lifecycle_args.append(str(mp3))
            result["mp3Lifecycle"] = "generated MP3 included"
        else:
            result["mp3Lifecycle"] = "SKIPPED: ffmpeg encoder unavailable"
        lifecycle, lifecycle_metrics = run_timed(app, lifecycle_args, scratch / "lifecycle.json", args.timeout)
        result["lifecycle"] = {"checks": lifecycle, **lifecycle_metrics}
        check("all lifecycle checks pass", all(item["passed"] for item in lifecycle), len(lifecycle))
        # This exercises the real local snapshot worker as a separate process.
        # It is not a download/placeholder simulation, nor a live iCloud test.
        snapshot_dir = scratch / "snapshot"
        snapshot_dir.mkdir()
        snapshot = snapshot_dir / "audio.wav"
        _, copy_metrics = run_timed(app, ["--prepare-input-worker", str(long_file), str(snapshot)],
                                    scratch / "copy-worker.stdout", args.timeout, expects_json=False)
        receipt = json.loads((snapshot_dir / "receipt.json").read_text())
        result["localSnapshotCopy"] = {"inputBytes": long_file.stat().st_size, "receipt": receipt, **copy_metrics}
        check("long local snapshot byte-identical", sha(snapshot) == sha(long_file))
        check("long local snapshot receipt complete", receipt["bytes"] == long_file.stat().st_size)
        check("local snapshot peak RSS below 128 MiB", copy_metrics["peakRSSBytes"] < 128 * 1024 ** 2,
              copy_metrics["peakRSSBytes"])
        shutil.rmtree(snapshot_dir)
        reports = []
        for path, seconds in [(baseline, args.baseline_seconds), (long_file, args.seconds)]:
            original_hash = sha(path)
            report, metrics = run_timed(app, ["--analyze", str(path)], scratch / (path.stem + ".json"), args.timeout)
            reports.append(report)
            result["runs"].append({"durationSeconds": seconds, "inputBytes": path.stat().st_size,
                                   "frames": report["frames"], "integrated": report["integrated"],
                                   "samplePeak": report["samplePeak"], "truePeakEstimate": report["truePeakEstimate"],
                                   "toneSlices": len(report["toneSlices"]), "dynamicsSlices": len(report["dynamics"]),
                                   **metrics})
            check(f"{seconds}s frames complete", report["frames"] == seconds * args.rate)
            check(f"{seconds}s source unchanged", sha(path) == original_hash)
        short, long = reports
        check("duration-independent integrated loudness", abs(short["integrated"] - long["integrated"]) < 0.05,
              {"short": short["integrated"], "long": long["integrated"]})
        check("duration-independent sample peak", abs(short["samplePeak"] - long["samplePeak"]) < 1e-6)
        short_rss, long_rss = (r["peakRSSBytes"] for r in result["runs"])
        check("long analysis peak RSS below 512 MiB", long_rss < 512 * 1024 ** 2, long_rss)
        check("RSS growth below 128 MiB", long_rss - short_rss < 128 * 1024 ** 2, long_rss - short_rss)
        result["storagePolicy"] = "Generated WAV/MP3, full JSON and transient profiler output deleted by TemporaryDirectory; compact measurements retained."
    result["passed"] = all(check["passed"] for check in result["checks"])
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"passed": result["passed"], "output": str(output), "runs": result["runs"],
                      "mp3Lifecycle": result["mp3Lifecycle"]}, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
