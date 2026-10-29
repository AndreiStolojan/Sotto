"""Bookkeeping tests only. All audio is generated silence; all timings are invented."""

import csv
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("benchmark", ROOT / "scripts/benchmark.py")
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)

CSV_FIELDS = [
    "Original Transcript", "Enhanced Transcript", "Enhancement Model", "Prompt Name",
    "Transcription Model", "Mode", "Enhancement Time", "Transcription Time", "Timestamp", "Duration",
]


class CorpusTests(unittest.TestCase):
    def test_balance_and_schedule(self):
        samples = bench.samples_from(bench.read_json(ROOT / "docs/benchmarks/prompts.json"))
        planned = bench.plan(samples, 3)
        self.assertEqual(len(planned), 273)
        for model in bench.MODELS:
            block = [r for r in planned if r["model"] == model]
            self.assertEqual(block[0]["phase"], "first")
            self.assertEqual(block[0]["sample_id"], "ro01")
            self.assertEqual(len([r for r in block if r["phase"] == "first"]), 1)
            for repeat in ("1", "2", "3"):
                self.assertEqual({r["sample_id"] for r in block if r["repeat"] == repeat}, {s["id"] for s in samples})
        self.assertEqual(len({r["run_id"] for r in planned}), 273)

    def test_word_errors_and_literal_critical_phrases(self):
        self.assertEqual(bench.distance(bench.tokens("Nu șterge raport.csv."), bench.tokens("Șterge raport csv")), 3)
        self.assertEqual(bench.distance(["x"], ["a", "b", "c"]), 3)
        self.assertEqual(bench.tokens("ȘTIE s\u0326tie README.md backup.tar.gz"), ["știe", "știe", "readme.md", "backup.tar.gz"])
        self.assertFalse(bench.contains(bench.tokens("120"), "12"))
        self.assertFalse(bench.contains(bench.tokens("nu publica"), "nu trimite"))
        self.assertFalse(bench.contains(bench.tokens("report csv"), "report.csv"))
        self.assertTrue(bench.contains(bench.tokens("Do NOT delete."), "not"))


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.workspace = Path(self.temporary.name) / "private"
        bench.initialize(self.workspace, 1, "ggml-base")
        manifest = bench.read_json(self.workspace / "manifest.json")
        # Distinct lengths make source-to-export duration checks observable.
        for i, sample in enumerate(manifest["samples"]):
            with wave.open(str(self.workspace / sample["audio"]), "wb") as output:
                output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                output.writeframes(b"\x00\x00" * (16000 + i * 2000))
        session = bench.read_json(self.workspace / "session.json")
        for key in ("hardware", "macos", "app_commit", "settings_notes", "dictionary_sha256",
                    "model_files_notes", "prewarm_notes", "replacement_profile"):
            session[key] = "SYNTHETIC TEST FIXTURE ONLY"
        session["operator_confirmed_same_audio"] = True
        bench.write_json(self.workspace / "session.json", session)
        bench.seal(self.workspace)

    def load_runs(self):
        with (self.workspace / "runs.csv").open(newline="", encoding="utf-8") as source:
            return list(csv.DictReader(source))

    def save_runs(self, rows):
        with (self.workspace / "runs.csv").open("w", newline="", encoding="utf-8") as output:
            writer = csv.DictWriter(output, fieldnames=bench.RUN_FIELDS)
            writer.writeheader()
            writer.writerows(rows)

    def export(self, rows):
        with (self.workspace / "exports/fixture.csv").open("w", newline="", encoding="utf-8") as output:
            writer = csv.DictWriter(output, fieldnames=CSV_FIELDS)
            writer.writeheader()
            writer.writerows(rows)

    def fill_successes(self):
        samples = {s["id"]: s for s in bench.read_json(self.workspace / "manifest.json")["samples"]}
        rows = self.load_runs()
        observations = []
        # Reverse the export to verify that scoring follows explicit row assignments.
        for index, row in enumerate(reversed(rows), 1):
            sample = samples[row["sample_id"]]
            text = sample["reference"]
            if row["run_id"] == "v3-warm-1-ro01":
                text = "Șterge cele 17 înregistrări din raport.csv."  # Deleted negation.
            if row["run_id"] == "ultra-warm-1-en01":
                text = ""  # Successful empty recognition must not disappear.
            if row["run_id"] == "whisper-warm-1-mixed01":
                text += '\nSYNTHETIC "quoted", extra text.'
            observations.append(dict(zip(CSV_FIELDS, [
                text, "", "", "", {**bench.MODELS, "whisper": "Base"}[row["model"]], "fixture",
                "0", "0.25" if row["phase"] == "warm" else "4", str(index), str(sample["duration_s"]),
            ])))
            row.update(status="ok", csv_file="exports/fixture.csv", csv_row=str(index))
        self.export(observations)
        self.save_runs(rows)
        return rows, observations

    def test_end_to_end_synthetic_scoring(self):
        self.fill_successes()
        report = bench.score(self.workspace)
        self.assertTrue(report["complete"])
        self.assertEqual(report["collection_kind"], "synthetic")
        self.assertIsNone(report["stop_to_paste_s"])
        self.assertEqual(report["groups"]["v3/first/all"]["recognition_s"]["median"], 4)
        warm = report["groups"]["v3/warm/all"]
        self.assertEqual(warm["recognition_s"]["median"], .25)
        self.assertEqual(warm["recognition_s"]["n"], 30)
        self.assertEqual(warm["critical_missing"]["negations"], 1)
        words = sum(len(bench.tokens(s["reference"])) for s in bench.read_json(self.workspace / "manifest.json")["samples"])
        self.assertEqual(warm["wer"], 1 / words)
        self.assertGreater(report["groups"]["ultra/warm/en"]["wer"], 0)
        quoted = next(r for r in report["runs"] if r["run_id"] == "whisper-warm-1-mixed01")
        self.assertGreater(quoted["word_errors"], 0)
        self.assertEqual(len(report["exports_sha256"]), 1)
        json.dumps(report, allow_nan=False)
        command = subprocess.run(
            [sys.executable, str(ROOT / "scripts/benchmark.py"), "score", str(self.workspace)],
            text=True, capture_output=True, check=True,
        )
        self.assertEqual(json.loads(command.stdout), report)

    def test_unrecorded_workspace_cli_does_not_generate_observations(self):
        workspace = self.workspace.parent / "unrecorded"
        script = str(ROOT / "scripts/benchmark.py")
        subprocess.run([sys.executable, script, "init", str(workspace)], check=True)
        self.assertEqual(list((workspace / "audio").iterdir()), [])
        self.assertEqual(list((workspace / "exports").iterdir()), [])
        result = subprocess.run([sys.executable, script, "seal", str(workspace)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Missing or non-local evidence", result.stderr)
        self.assertFalse((workspace / "corpus.sha256").exists())

    def test_rejects_wrong_audio_format_and_truncated_csv(self):
        path = self.workspace.parent / "stereo.wav"
        with wave.open(str(path), "wb") as output:
            output.setparams((2, 2, 16000, 0, "NONE", "not compressed"))
            output.writeframes(b"\x00\x00\x00\x00" * 16000)
        with self.assertRaisesRegex(ValueError, "mono PCM16"):
            bench.audio_metadata(path)
        with (self.workspace / "runs.csv").open("a", encoding="utf-8") as output:
            output.write("incomplete,row\n")
        with self.assertRaisesRegex(ValueError, "Truncated"):
            bench.score(self.workspace)

    def test_requires_operator_settings_confirmation(self):
        session = bench.read_json(self.workspace / "session.json")
        session["operator_confirmed_same_audio"] = False
        bench.write_json(self.workspace / "session.json", session)
        with self.assertRaisesRegex(ValueError, "Confirm identical audio"):
            bench.score(self.workspace)

    def test_pending_and_failed_attempts_remain_in_denominator(self):
        rows = self.load_runs()
        rows[1].update(status="error", error="SYNTHETIC unavailable model")
        self.save_runs(rows)
        report = bench.score(self.workspace)
        self.assertFalse(report["complete"])
        warm = report["groups"]["v3/warm/all"]
        self.assertEqual((warm["planned"], warm["error"], warm["pending"], warm["ok"]), (30, 1, 29, 0))
        self.assertIsNone(warm["wer"])
        self.assertIsNone(warm["recognition_s"]["median"])

    def test_changed_audio_and_reference_are_rejected(self):
        path = self.workspace / "audio/ro01.wav"
        original = path.read_bytes()
        path.write_bytes(original[:-2] + b"\x01\x00")
        with self.assertRaisesRegex(ValueError, "Audio changed"):
            bench.score(self.workspace)
        path.write_bytes(original)
        manifest_path = self.workspace / "manifest.json"
        manifest = bench.read_json(manifest_path)
        manifest["samples"][0]["reference"] = "Edited after freezing"
        bench.write_json(manifest_path, manifest)
        with self.assertRaisesRegex(ValueError, "Manifest changed"):
            bench.score(self.workspace)

    def test_refuses_overwrite_and_non_local_evidence(self):
        with self.assertRaises(FileExistsError):
            bench.initialize(self.workspace, 1, "ggml-base")
        with self.assertRaisesRegex(ValueError, "already sealed"):
            bench.seal(self.workspace)
        outside = Path(self.temporary.name) / "outside.csv"
        outside.write_text("private", encoding="utf-8")
        (self.workspace / "exports/link.csv").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "non-local"):
            bench.local_file(self.workspace, "exports/link.csv")

    def test_export_errors_are_rejected(self):
        rows, observations = self.fill_successes()
        for column, value, message in (
            ("Transcription Model", "wrong model", "model does not match"),
            ("Enhanced Transcript", "cleanup", "Cleanup"),
            ("Duration", "99", "duration differs"),
            ("Transcription Time", "NaN", "finite positive"),
            ("Transcription Time", "0", "finite positive"),
        ):
            with self.subTest(column=column, value=value):
                old = observations[0][column]
                observations[0][column] = value
                self.export(observations)
                with self.assertRaisesRegex(ValueError, message):
                    bench.score(self.workspace)
                observations[0][column] = old
        self.export(observations)
        rows[1]["csv_row"] = rows[0]["csv_row"]
        self.save_runs(rows)
        with self.assertRaisesRegex(ValueError, "Duplicate observation"):
            bench.score(self.workspace)

    def test_subset_export_cannot_reuse_an_observation(self):
        rows, observations = self.fill_successes()
        # A second export contains the same record at a different row number.
        duplicate = self.workspace / "exports/subset.csv"
        with duplicate.open("w", newline="", encoding="utf-8") as output:
            writer = csv.DictWriter(output, fieldnames=CSV_FIELDS)
            writer.writeheader()
            writer.writerow(observations[int(rows[0]["csv_row"]) - 1])
        rows[1].update(csv_file="exports/subset.csv", csv_row="1")
        self.save_runs(rows)
        with self.assertRaisesRegex(ValueError, "Duplicate observation"):
            bench.score(self.workspace)

    def test_missing_and_duplicate_runs_are_rejected(self):
        rows = self.load_runs()
        self.save_runs(rows[:-1])
        with self.assertRaisesRegex(ValueError, "planned runs"):
            bench.score(self.workspace)
        self.save_runs(rows[:-1] + [rows[0]])
        with self.assertRaisesRegex(ValueError, "planned runs"):
            bench.score(self.workspace)


class LatencyTests(unittest.TestCase):
    def parse(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.log"
            path.write_text(text, encoding="utf-8")
            return bench.latency(path)

    def test_log_scopes_and_failed_pastes(self):
        # Invented values, matching the production DictationLatencyTrace format.
        first = 'prefix dictation first=true engine=FluidAudio model=Parakeet V3 audio=2.000s finalize=0.100s transcribe=0.500s enhance=- insert=0.200s total=0.900s inserted=true'
        warm = first.replace("first=true", "first=false").replace("0.500s", "0.300s")
        failed = warm.replace("inserted=true", "inserted=false")
        report = self.parse("unrelated log\n" + first + "\n" + warm + "\n" + failed)
        group = report["groups"]["FluidAudio/Parakeet V3/warm"]
        self.assertEqual((group["attempts"], group["failed"]), (2, 1))
        self.assertEqual(group["recognition_s"], {"n": 1, "median": .3, "p95": .3})
        self.assertEqual(group["stop_to_paste_command_s"]["median"], .9)
        self.assertEqual(group["runs"][0]["line"], 3)

    def test_early_failure_has_unknown_phase(self):
        report = self.parse("dictation first=false engine=- model=- audio=0.000s finalize=0.010s transcribe=- enhance=- insert=0.010s total=0.020s inserted=false")
        group = report["groups"]["-/-/unknown"]
        self.assertEqual(group["failed"], 1)
        self.assertEqual(group["recognition_s"]["n"], 0)
        self.assertIsNone(group["stop_to_paste_command_s"]["median"])

    def test_rejects_nonfinite_audio_duration(self):
        audio = "9" * 400
        with self.assertRaisesRegex(ValueError, "Invalid log timing"):
            self.parse(f"dictation first=true engine=Whisper model=Base audio={audio}s finalize=0.010s transcribe=0.100s enhance=- insert=0.010s total=0.120s inserted=true")

    def test_rejects_missing_and_malformed_timings(self):
        with self.assertRaisesRegex(ValueError, "No DictationLatency"):
            self.parse("no measurements")
        with self.assertRaisesRegex(ValueError, "Malformed"):
            self.parse("dictation first=true incomplete")
        with self.assertRaisesRegex(ValueError, "Missing successful"):
            self.parse("dictation first=true engine=Whisper model=Large v3 Turbo audio=2.000s finalize=- transcribe=- enhance=- insert=- total=0.100s inserted=true")


if __name__ == "__main__":
    unittest.main()
