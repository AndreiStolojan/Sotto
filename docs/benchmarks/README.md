# Private dictation benchmark

This protocol compares Parakeet V3, Parakeet Ultra and one exact multilingual Whisper model on the same 30 local recordings. It measures the existing app path. It does not call an API, capture a microphone, upload files or produce engine observations itself. Python 3.11 or newer is required. No Python packages are needed.

No real audio or measured model results ship with this protocol. Tests generate silent WAV files and invented CSV/log values in temporary directories to check bookkeeping only.

## Prepare the corpus

From the Sotto checkout:

```sh
python3 scripts/benchmark.py init .benchmark-private/m2-run-01
```

The new directory has private directory permissions and is ignored by Git. Prefer a local folder outside iCloud Drive, Dropbox or other sync folders. The command refuses to overwrite an existing workspace. It creates:

- `manifest.json`: 10 Romanian, 10 English and 10 mixed technical sentences, with references and critical numbers, negations and filenames.
- `audio/`: the 30 WAV files you will supply.
- `session.json`: machine, build, model, settings and dictionary metadata to fill in.
- `runs.csv`: the attempt schedule and explicit links to History CSV data rows.
- `exports/`: a place for private History exports.

Choose the Whisper variant before starting, for example `--whisper ggml-large-v3-turbo-q5_0`. The default is `ggml-large-v3-turbo`. English-only models are excluded. Do not pool different sizes or quantizations under one Whisper result. Use a new workspace for each configuration.

On the Mac, Andrei can record each reference with QuickTime Player: File > New Audio Recording, select the intended microphone, explicitly press Record, read one sentence, then stop and save locally as `ro01.m4a`, and so on. Nothing in this harness listens to the microphone. Speak numbers naturally. Speak filename punctuation, for example "raport punct CSV" or "package dot JSON". Record only the sample sentence. Listen back, trim accidental speech and long silence, and check for clipping. If a spoken word differs, re-record or correct the reference before running any engine.

Convert each recording using the macOS tool, without uploading it:

```sh
afconvert -f WAVE -d LEI16@16000 -c 1 ro01.m4a .benchmark-private/m2-run-01/audio/ro01.wav
```

Repeat for all 30 IDs. Keep original recordings privately. The evaluation inputs must be mono PCM16 WAV at 16 kHz. Do not re-record for each model. Freeze the references after listening, before seeing engine output:

```sh
python3 scripts/benchmark.py seal .benchmark-private/m2-run-01
```

Sealing records audio SHA-256 and duration and hashes the entire manifest. Scoring checks them again. A sealed corpus cannot be resealed. Start a new workspace if audio or references need correction. Hashes detect accidental changes; they are not proof that the operator imported the correct file.

## Hold the settings constant

Download the three models yourself in the existing model library before timing. Evaluation then works offline. Do not include download time. Do not use `install.sh` for validation: it installs and opens an app. Build only with `scripts/build.sh` if needed; do not replace the installed app to run this protocol.

Use one dictation mode with Auto-detect language, realtime transcription off, cleanup off, custom commands off, screen/clipboard/selection context off, Auto Learn off, text formatting off and VAD off. Record all settings in `settings_notes`. VAD off preserves the same audio across engines. For this baseline, use Auto-detect on Parakeet too, rather than the default Latin filter. A Latin-filter or forced-language experiment needs its own workspace.

Use the existing dictionary export to save a private JSON snapshot and record its SHA-256 in `dictionary_sha256`. Keep replacements unchanged for all attempts. `replacement_profile` names the frozen dictionary configuration. Vocabulary feeds optional cleanup; with cleanup off it is not an ASR vocabulary hint. The exported Original Transcript already includes the app's output filter and word replacements. Call the result *app output WER*, not raw engine WER. To test replacements, repeat with another frozen dictionary in another workspace. Do not reimplement replacements in the scorer or tune them midway through a run.

Fill in `session.json`:

- `collection_kind`: change `synthetic` to `human` only after supplying real recordings. Initialization deliberately defaults to `synthetic`.
- `hardware`, `macos`, `app_commit`: exact device, OS, app version/channel and build commit. For a modified build, record that fact and a patch hash too.
- `model_files_notes`: exact model IDs and local file hashes or revision and precision, including the Whisper variant. Do not record only "Whisper".
- `prewarm_notes`: whether Prewarm Model on Wake is on, launch/wake activity, model selection/loading and any automatic Whisper warmup. `first` is not a promise of a cold model or empty OS caches.
- `operator_confirmed_same_audio`: set to `true` after checking that every model received the sealed files.
- Keep the baseline booleans false and `language` set to `auto`.

Stay on the same power source, close heavy jobs, note low-power mode and thermal conditions, and avoid sleep or model changes during a block. Do not clear system caches. Record engine block order. Rotate that order in later whole-workspace replications to expose thermal/order effects.

## Run through the existing app

The harness uses Audio Import, History CSV export, the existing `TranscriptionServiceRegistry`, and dictionary processing. It adds no new recognition engine or UI.

For each model block in `runs.csv`:

1. Select the correct model and benchmark mode. Quit and reopen the intended app yourself. Confirm the model/mode after opening. Record prewarming activity.
2. Import only `ro01.wav` as the first request. Keep its result. This row is `phase=first, repeat=0` and is excluded from warm summaries.
3. In the same app process, import all 30 sealed WAV files one at a time in manifest order. This is warm repeat 1. Repeat for passes 2 and 3 without changing model, settings or files. The default plan has 91 attempts per model, 273 total.
4. Export just these results from History. Copy the CSV into `exports/`. For each planned row, enter `status=ok`, `csv_file=exports/v3.csv` (for example), and `csv_row`. The row number is one-based among CSV **data records**, excluding the header. Quoted multiline transcripts occupy one record. Export selection order is not guaranteed. Use timestamps, a local attempt notebook and one-at-a-time imports to map rows. The export contains no source filename, so do not guess by row order or transcript similarity.
5. If an attempt fails, set `status=error` with a concrete `error` description. Leave unattempted rows `pending`. Empty successful transcripts stay `ok` and count as recognition errors. Do not silently delete or replace failures. Record a retry in a fresh workspace if needed.

Important timing limit: Audio Import constructs a new registry per file. Parakeet can load a fresh ASR manager on each attempt. Whisper can reuse the shared model provider. Therefore `warm` means a repeated request in the same app process, with available OS/model caches. It does **not** establish equal model residency or kernel-only inference speed. History retranscription also creates new service instances at its call sites, so it does not fix this limitation. Keep this app-path comparison separate from a future retained-engine microbenchmark.

The first-request probe uses only `ro01` in each model block. Its sample count is one per model and is not a corpus-wide first-run distribution. To investigate startup variance, repeat whole workspaces. Do not pool first and warm rows.

## Calculate results

```sh
python3 scripts/benchmark.py score .benchmark-private/m2-run-01 > .benchmark-private/m2-run-01/report.json
```

The scorer refuses changed audio/references, missing metadata, wrong models, duplicate CSV observations, cleanup output, invalid durations and nonfinite timings. It reports `complete=false` while any attempt is pending or failed. Partial summaries are descriptive only; do not compare engines with different missing samples. Evidence hashes and per-run source record numbers remain in the private report.

Each model/phase/language group includes:

- WER: word insertions + deletions + substitutions divided by reference words, pooled over successful attempts. It can exceed 1. Case and outer punctuation are ignored; diacritics, digits and internal filename separators remain. `17` and `seventeen` differ. Review number-formatting differences separately before calling them recognition mistakes.
- Strict exact rate: the entire trimmed NFC-normalized output must match, including case and punctuation.
- Missing critical phrases and their denominators for numbers, negations and filenames. These are literal token/phrase checks, not semantic correctness. A negation in the wrong place, an extra number or a repeated word can escape this check. Review every critical mismatch and any changed meaning manually.
- Recognition duration: median and nearest-rank p95 from History's `Transcription Time`, in seconds. For Audio Import this surrounds the service call, including lazy loading, language handling, audio preparation inside the provider and decoding. It excludes earlier import conversion, dictionary work, saving and paste.
- RTF: recognition seconds divided by audio seconds. Below 1 means processing faster than the recording's duration. This does not measure streaming responsiveness.

With only 30 short samples from one speaker, results describe this corpus and device. The three repeated passes reuse the same speech; they are not 90 independent utterances.

## Measure stop-to-paste separately

Imported files do not execute the stop/paste path. Their report leaves `stop_to_paste_s=null`. Never substitute recognition time for it.

For a companion live check, Andrei can deliberately dictate the same prompts into a blank local TextEdit document, with the same settings. Start the existing log stream before dictating, then stop it with Control-C:

```sh
/usr/bin/log stream --style compact --level notice \
  --predicate 'subsystem == "ro.andrei.Voce" AND category == "DictationLatency"' \
  > .benchmark-private/m2-run-01/live.log
python3 scripts/benchmark.py latency .benchmark-private/m2-run-01/live.log \
  > .benchmark-private/m2-run-01/live-report.json
```

Restart the intended app before each model block so `first=true` belongs to that block. The flag is global to the app process, not per model. Prewarming can still have happened. Leave realtime off. The parser separates first/warm and models, includes failed paste counts, preserves component timings and reports medians/p95 only for `inserted=true` attempts. Failures before transcription have unknown model/phase and stay in an `unknown` group.

`transcribe` runs from finalized audio to filtered transcription; `total` runs from stop request until the paste task returns. That task acknowledges posting a paste command. `inserted=true` does not prove the target received the text. Check the actual TextEdit contents for every attempt and note missing/duplicated text. Complete stop-to-visible-text latency still requires a local screen recording or an observer, with an explicit stop marker and first visible text frame. Record frame rate and estimate uncertainty of at least one frame. Do not label `total` as that measurement.

Live takes are different audio, so this companion report is not the identical-audio model comparison. A future loopback test must route each sealed file through an explicitly chosen local input and record routing delay; this harness neither configures audio devices nor changes permissions.

## Verification and remaining device work

```sh
python3 -m unittest discover -s Tests/Benchmark -v
```

The tests use synthetic silence and explicit invented exports/logs. They check corpus balance, first/warm schedules, sealing, row mapping, scoring, failures and parsing. They do not run Parakeet or Whisper.

On a Mac, also run the project's existing checks when changing app code. This harness changes no app code. Remaining work is Andrei's 30 real recordings, reviewed references, frozen settings/dictionary/model identities, actual on-device attempts and target-paste checks. Keep audio, transcripts, dictionary exports and reports private unless Andrei explicitly chooses to share them.
