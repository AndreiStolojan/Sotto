#!/usr/bin/env python3
"""Prepare and score a private Sotto corpus using existing History CSV and latency logs.

Standard library only. Never records, starts an engine, runs a command or uses the network.
"""

import argparse
import csv
import hashlib
import json
import math
import re
import statistics
import unicodedata
import wave
from collections import Counter, defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODELS = {"v3": "Parakeet V3", "ultra": "Parakeet Ultra", "whisper": "Large v3 Turbo"}
WHISPER = {
    "ggml-tiny": "Tiny", "ggml-base": "Base", "ggml-large-v2": "Large v2",
    "ggml-large-v3": "Large v3", "ggml-large-v3-turbo": "Large v3 Turbo",
    "ggml-large-v3-turbo-q5_0": "Large v3 Turbo (Quantized)",
}
RUN_FIELDS = ["run_id", "model", "sample_id", "phase", "repeat", "status", "csv_file", "csv_row", "error"]
CATEGORIES = ("numbers", "negations", "filenames")
EXPORT_FIELDS = [
    "Original Transcript", "Enhanced Transcript", "Enhancement Model", "Prompt Name",
    "Transcription Model", "Mode", "Enhancement Time", "Transcription Time", "Timestamp", "Duration",
]


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def read_csv(path: Path, fields: list[str]) -> list[dict[str, str]]:
    """Reject truncated rows and schema drift instead of guessing missing measurements."""
    with path.open(encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source, strict=True)
        if reader.fieldnames != fields:
            raise ValueError(f"Unexpected CSV header: {path.name}")
        rows = list(reader)
    if any(None in row or any(row[key] is None for key in fields) for row in rows):
        raise ValueError(f"Truncated or extra CSV fields: {path.name}")
    return rows


def sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def local_file(workspace: Path, name: str) -> Path:
    """Keep evidence paths inside the private workspace, including through symlinks."""
    path = (workspace / name).resolve()
    if not name or not path.is_relative_to(workspace.resolve()) or not path.is_file():
        raise ValueError(f"Missing or non-local evidence: {name}")
    return path


def tokens(text: str) -> list[str]:
    """Fold case and outer punctuation, preserving diacritics, digits and file separators."""
    return re.findall(r"\w+(?:[./:-]\w+)*", unicodedata.normalize("NFC", text).casefold())


def distance(reference: list[str], hypothesis: list[str]) -> int:
    """Count word insertions, deletions and substitutions using Levenshtein distance."""
    previous = list(range(len(hypothesis) + 1))
    for i, expected in enumerate(reference, 1):
        current = [i]
        for j, actual in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (expected != actual)))
        previous = current
    return previous[-1]


def contains(text: list[str], phrase: str) -> bool:
    expected = tokens(phrase)
    return any(text[i:i + len(expected)] == expected for i in range(len(text) - len(expected) + 1))


def samples_from(manifest: dict) -> list[dict]:
    samples = manifest["samples"]
    if manifest["schema_version"] != 1 or len(samples) != 30:
        raise ValueError("Expected schema 1 and exactly 30 samples")
    if Counter(s["language"] for s in samples) != {"ro": 10, "en": 10, "mixed": 10}:
        raise ValueError("Expected 10 Romanian, 10 English and 10 mixed samples")
    if len({s["id"] for s in samples}) != 30:
        raise ValueError("Duplicate sample IDs")
    for sample in samples:
        if not tokens(sample["reference"]):
            raise ValueError(f"Empty reference: {sample['id']}")
        for category in CATEGORIES:
            for phrase in sample["critical"][category]:
                if not tokens(phrase) or not contains(tokens(sample["reference"]), phrase):
                    raise ValueError(f"Critical phrase missing from reference: {phrase}")
    return samples


def plan(samples: list[dict], repeats: int) -> list[dict]:
    """One first request and repeated full corpus passes per model, in one app session."""
    rows = []
    for model in MODELS:
        schedule = [("first", 0, samples[0])]
        schedule += [("warm", repeat, sample) for repeat in range(1, repeats + 1) for sample in samples]
        for phase, repeat, sample in schedule:
            rows.append(dict(zip(RUN_FIELDS, [
                f"{model}-{phase}-{repeat}-{sample['id']}", model, sample["id"], phase,
                str(repeat), "pending", "", "", "",
            ])))
    return rows


def initialize(workspace: Path, repeats: int, whisper: str) -> None:
    if repeats < 1:
        raise ValueError("At least one warm repeat is required")
    manifest = read_json(ROOT / "docs/benchmarks/prompts.json")
    samples = samples_from(manifest)
    workspace.mkdir(mode=0o700, parents=True, exist_ok=False)
    (workspace / "audio").mkdir(mode=0o700)
    (workspace / "exports").mkdir(mode=0o700)
    for sample in samples:
        sample.update(audio=f"audio/{sample['id']}.wav", sha256=None, duration_s=None)
    write_json(workspace / "manifest.json", manifest)
    write_json(workspace / "session.json", {
        "schema_version": 1, "repeats": repeats, "whisper_model": whisper,
        "hardware": "", "macos": "", "app_commit": "", "settings_notes": "",
        "dictionary_sha256": "", "model_files_notes": "", "prewarm_notes": "",
        "collection_kind": "synthetic", "language": "auto", "cleanup_enabled": False,
        "realtime_enabled": False, "formatting_enabled": False, "vad_enabled": False,
        "replacement_profile": "", "operator_confirmed_same_audio": False,
    })
    with (workspace / "runs.csv").open("w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=RUN_FIELDS)
        writer.writeheader()
        writer.writerows(plan(samples, repeats))


def audio_metadata(path: Path) -> tuple[str, float]:
    with wave.open(str(path), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, 16000, "NONE"):
            raise ValueError(f"Expected mono PCM16 16 kHz WAV: {path.name}")
        frames = audio.getnframes()
        if frames == 0 or len(audio.readframes(frames)) != frames * 2:
            raise ValueError(f"Empty or truncated WAV: {path.name}")
    return sha256(path), frames / 16000


def seal(workspace: Path) -> None:
    """Freeze the reviewed references and local WAV identities before model evaluation."""
    manifest = read_json(workspace / "manifest.json")
    for sample in samples_from(manifest):
        sample["sha256"], sample["duration_s"] = audio_metadata(local_file(workspace, sample["audio"]))
    if (workspace / "corpus.sha256").exists():
        raise ValueError("Corpus already sealed; create a new workspace to change it")
    write_json(workspace / "manifest.json", manifest)
    (workspace / "corpus.sha256").write_text(sha256(workspace / "manifest.json") + "\n", encoding="utf-8")


def positive(value: str) -> float:
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise ValueError(f"Expected a finite positive measurement, got {value}")
    return number


def distribution(values: list[float]) -> dict:
    if not values:
        return {"n": 0, "median": None, "p95": None}
    ordered = sorted(values)
    return {"n": len(values), "median": statistics.median(values), "p95": ordered[math.ceil(len(values) * .95) - 1]}


def summarize(records: list[dict]) -> dict:
    successes = [r for r in records if r["status"] == "ok"]
    words = sum(r["reference_words"] for r in successes)
    return {
        "planned": len(records), "ok": len(successes),
        "error": sum(r["status"] == "error" for r in records),
        "pending": sum(r["status"] == "pending" for r in records),
        "wer": sum(r["word_errors"] for r in successes) / words if words else None,
        "strict_exact_rate": sum(r["strict_exact"] for r in successes) / len(successes) if successes else None,
        "critical_missing": {c: sum(len(r["missing"][c]) for r in successes) for c in CATEGORIES},
        "critical_total": {c: sum(r["critical_total"][c] for r in successes) for c in CATEGORIES},
        "recognition_s": distribution([r["recognition_s"] for r in successes]),
        "rtf": distribution([r["recognition_s"] / r["duration_s"] for r in successes]),
    }


def score(workspace: Path) -> dict:
    manifest_path = workspace / "manifest.json"
    if sha256(manifest_path) != (workspace / "corpus.sha256").read_text(encoding="utf-8").strip():
        raise ValueError("Manifest changed after sealing")
    samples = samples_from(read_json(manifest_path))
    by_id = {s["id"]: s for s in samples}
    for sample in samples:
        digest, duration = audio_metadata(local_file(workspace, sample["audio"]))
        if (digest, duration) != (sample["sha256"], sample["duration_s"]):
            raise ValueError(f"Audio changed after sealing: {sample['id']}")
    session = read_json(workspace / "session.json")
    for key in ("hardware", "macos", "app_commit", "settings_notes", "dictionary_sha256",
                "model_files_notes", "prewarm_notes", "replacement_profile"):
        if not isinstance(session[key], str) or not session[key].strip():
            raise ValueError(f"Complete session metadata: {key}")
    if (session["schema_version"] != 1 or session["collection_kind"] not in ("human", "synthetic")
            or session["operator_confirmed_same_audio"] is not True or session["language"] != "auto"
            or any(session[k] is not False for k in ("cleanup_enabled", "realtime_enabled", "formatting_enabled", "vad_enabled"))):
        raise ValueError("Confirm identical audio and baseline local settings in session.json")
    repeats = session["repeats"]
    if type(repeats) is not int or repeats < 1:
        raise ValueError("Invalid warm repeat count")
    model_names = {**MODELS, "whisper": WHISPER[session["whisper_model"]]}
    rows = read_csv(workspace / "runs.csv", RUN_FIELDS)
    expected = {r["run_id"]: r for r in plan(samples, repeats)}
    if len(rows) != len(expected) or {r["run_id"] for r in rows} != set(expected):
        raise ValueError("Missing, extra or duplicated planned runs")
    records, used = [], set()
    used_observations = set()
    evidence = {}
    exports_by_path: dict[Path, list[dict[str, str]]] = {}
    for row in rows:
        planned = expected[row["run_id"]]
        if any(row[k] != planned[k] for k in RUN_FIELDS[:5]):
            raise ValueError(f"Changed run identity: {row['run_id']}")
        sample = by_id[row["sample_id"]]
        record = {k: row[k] for k in RUN_FIELDS[:6]}
        record["language"] = sample["language"]
        if row["status"] not in ("ok", "pending", "error"):
            raise ValueError(f"Unknown status: {row['run_id']}")
        if row["status"] == "error":
            if not row["error"].strip():
                raise ValueError("Failed runs need an error description")
            record["error"] = row["error"]
        elif row["status"] == "ok":
            path = local_file(workspace, row["csv_file"])
            relative_path = str(path.relative_to(workspace.resolve()))
            if path not in exports_by_path:
                exports_by_path[path] = read_csv(path, EXPORT_FIELDS)
                evidence[relative_path] = sha256(path)
            # Content hash prevents reusing one observation through copied export files.
            identity = (evidence[relative_path], int(row["csv_row"]))
            if identity in used or identity[1] < 1:
                raise ValueError("Duplicate observation or invalid CSV data row")
            used.add(identity)
            if identity[1] > len(exports_by_path[path]):
                raise ValueError(f"CSV data row out of range: {row['run_id']}")
            observation = exports_by_path[path][identity[1] - 1]
            # Re-exporting a subset changes the file hash and record number, but
            # does not create a new observation. Fail rather than count it twice.
            observation_identity = tuple(observation[field] for field in EXPORT_FIELDS)
            if observation_identity in used_observations:
                raise ValueError("Duplicate observation across History exports")
            used_observations.add(observation_identity)
            if observation["Transcription Model"] != model_names[row["model"]]:
                raise ValueError(f"Export model does not match {row['run_id']}")
            if any(observation[k] for k in ("Enhanced Transcript", "Enhancement Model", "Prompt Name")) or float(observation["Enhancement Time"]) != 0:
                raise ValueError("Cleanup must be disabled for the baseline")
            duration = positive(observation["Duration"])
            if abs(duration - sample["duration_s"]) > .1:
                raise ValueError(f"Export duration differs from source WAV: {row['run_id']}")
            reference, hypothesis = tokens(sample["reference"]), tokens(observation["Original Transcript"])
            record.update(
                recognition_s=positive(observation["Transcription Time"]), duration_s=duration,
                reference_words=len(reference), word_errors=distance(reference, hypothesis),
                strict_exact=unicodedata.normalize("NFC", observation["Original Transcript"].strip()) == unicodedata.normalize("NFC", sample["reference"].strip()),
                missing={c: [p for p in sample["critical"][c] if not contains(hypothesis, p)] for c in CATEGORIES},
                critical_total={c: len(sample["critical"][c]) for c in CATEGORIES},
                csv_file=row["csv_file"], csv_row=identity[1], timestamp=observation["Timestamp"],
            )
        records.append(record)
    groups = defaultdict(list)
    for record in records:
        for language in ("all", record["language"]):
            groups[f"{record['model']}/{record['phase']}/{language}"].append(record)
    return {
        "schema_version": 1, "collection_kind": session["collection_kind"], "session": session,
        "corpus_sha256": sha256(manifest_path), "exports_sha256": evidence,
        "complete": all(r["status"] == "ok" for r in records),
        "timing_scope": "History file-import service call, including lazy model loading; process-warm is not guaranteed engine-resident",
        "stop_to_paste_s": None,
        "groups": {key: summarize(value) for key, value in groups.items()}, "runs": records,
    }


TRACE = re.compile(
    r"dictation first=(true|false) engine=(.*?) model=(.*?) audio=([\d.]+)s "
    r"finalize=(\S+) transcribe=(\S+) enhance=(\S+) insert=(\S+) total=(\S+) inserted=(true|false)(?!\w)"
)


def log_seconds(value: str) -> float | None:
    if value == "-":
        return None
    if not value.endswith("s"):
        raise ValueError(f"Invalid log timing: {value}")
    number = float(value[:-1])
    if not math.isfinite(number) or number < 0:
        raise ValueError(f"Invalid log timing: {value}")
    return number


def latency(log: Path) -> dict:
    """Read DictationLatency independently of file-import recognition measurements."""
    groups = defaultdict(list)
    for line_number, line in enumerate(log.read_text(encoding="utf-8").splitlines(), 1):
        if "dictation first=" not in line:
            continue
        match = TRACE.search(line)
        if not match:
            raise ValueError(f"Malformed DictationLatency line {line_number}")
        first, engine, model, audio, finalize, transcribe, enhance, insert, total, inserted = match.groups()
        record = dict(line=line_number, first=first == "true", inserted=inserted == "true", audio_s=log_seconds(audio + "s"),
                      finalize_s=log_seconds(finalize), recognition_s=log_seconds(transcribe), enhancement_s=log_seconds(enhance),
                      insert_s=log_seconds(insert), stop_to_paste_command_s=log_seconds(total))
        if record["inserted"] and any(record[k] is None for k in ("finalize_s", "recognition_s", "insert_s", "stop_to_paste_command_s")):
            raise ValueError(f"Missing successful timing on line {line_number}")
        # Failures before markTranscribed have neither a model nor a meaningful first flag.
        phase = "unknown" if engine == "-" or transcribe == "-" else "first" if record["first"] else "warm"
        groups[f"{engine}/{model}/{phase}"].append(record)
    if not groups:
        raise ValueError("No DictationLatency observations found")
    return {
        "log_sha256": sha256(log), "scope": "live dictation, separate audio; first is app-global, paste is command acknowledgement, target visibility unverified",
        "groups": {key: {
            "attempts": len(rows), "failed": sum(not r["inserted"] for r in rows),
            "recognition_s": distribution([r["recognition_s"] for r in rows if r["inserted"]]),
            "stop_to_paste_command_s": distribution([r["stop_to_paste_command_s"] for r in rows if r["inserted"]]),
            "runs": rows,
        } for key, rows in groups.items()},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init", help="Create a new private workspace, never overwrite")
    init.add_argument("workspace", type=Path)
    init.add_argument("--repeats", type=int, default=3)
    init.add_argument("--whisper", choices=WHISPER, default="ggml-large-v3-turbo")
    for name in ("seal", "score"):
        commands.add_parser(name).add_argument("workspace", type=Path)
    commands.add_parser("latency").add_argument("log", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "init":
            initialize(args.workspace, args.repeats, args.whisper)
        elif args.command == "seal":
            seal(args.workspace)
        else:
            result = score(args.workspace.resolve()) if args.command == "score" else latency(args.log)
            print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))
    except (ValueError, KeyError, IndexError, OSError, wave.Error, csv.Error) as error:
        parser.exit(2, f"benchmark: {error}\n")


if __name__ == "__main__":
    main()
