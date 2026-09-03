# meet

Records meetings — your microphone and the other side's system audio, at
the same time, without any audio rerouting or virtual devices — and
transcribes the recording locally with a pluggable speech-to-text (STT)
engine. Runs entirely on your Mac: no audio or transcript leaves the
machine unless you point the STT command at something that sends it
somewhere.

## Requirements

- macOS 15 or later.
- A Swift toolchain to build (Swift 6, ships with recent Xcode / Xcode
  Command Line Tools).
- An STT command-line engine on your `PATH`. The default is
  [`parakeet-mlx`](https://github.com/senstella/parakeet-mlx), Apple
  Silicon-only:
  ```
  uv tool install parakeet-mlx
  ```
  or
  ```
  pipx install parakeet-mlx
  ```
  The default model is `parakeet-tdt-0.6b-v3`, which is multilingual and
  auto-detects language per utterance.

## Install

```
swift build -c release
cp .build/release/meet /usr/local/bin/   # or anywhere else on your PATH
```

## Usage

Run `meet` with no arguments to start interactive recording mode. It stays
open in a terminal corner for the whole day; each keypress controls the
current recording:

| Key     | Action                                  |
|---------|------------------------------------------|
| `z`     | Start a recording, or stop the current one |
| `space` | Pause / resume the current recording     |
| `q`     | Quit (stops any active recording first)  |

Stopping a recording queues it for transcription in the background, so you
can start the next recording immediately; `meet` prints `✓ <session>:
transcript ready` when a transcript finishes assembling. Pressing Ctrl+C
once waits for any in-flight transcriptions to finish before exiting;
pressing it a second time exits immediately (the recorded audio is safe
either way — nothing is deleted, and `meet process` catches up later).

To (re)run the transcription pipeline over recordings that didn't finish —
after a crash, an STT engine failure, or a config change:

```
meet process <folder>       # one session folder
meet process --all          # every session under recordings_dir
meet process --all --force  # redo every stage, even already-completed ones
```

`--force` is what you want after switching STT engines or models and
wanting old sessions re-transcribed with the new one.

## Permissions

`meet` needs two macOS permissions, and they behave very differently:

- **Microphone** prompts normally the first time you run `meet` — accept
  the system dialog.
- **System Audio Recording** does **not** prompt. macOS creates the
  Core Audio tap that captures the other side's audio silently; if the
  permission isn't granted, the recording simply contains silence and no
  error is raised anywhere. You have to grant it yourself, in advance:
  open **System Settings → Privacy & Security → Screen & System Audio
  Recording**, find the **System Audio Recording Only** section, click
  **+**, and add the terminal app you run `meet` from (Terminal, iTerm,
  Warp, etc.).

Both permissions are tied to the terminal app's identity, not to `meet`
itself — if you switch terminal apps, grant System Audio Recording again
for the new one.

Bluetooth headsets running in hands-free/handsfree mode drop their input
to 16 kHz; `meet` resamples whatever the hardware provides, so recording
and transcription quality are unaffected either way — parakeet operates at
16 kHz internally regardless of the source sample rate.

## Configuration

`meet` reads `~/.config/meet/config.toml` if it exists; every key is
optional and falls back to the default shown below.

```toml
# Where session folders are created.
recordings_dir = "~/MeetingRecordings"

[stt]
# Template for the STT engine invocation. {audio} and {outdir} are
# substituted with shell-quoted paths before the command runs.
command = "parakeet-mlx {audio} --output-format json --output-dir {outdir}"

[transcript]
# Consecutive segments from the same speaker with a gap shorter than this
# (in seconds) are merged into one utterance in transcript.md.
merge_gap_seconds = 2.0
# Speaker labels used in transcript.md.
speaker_me = "Me"
speaker_them = "Them"
```

### STT contract

`meet` treats the STT engine as an external process. It runs your
`stt.command` once per audio track (once for the mic, once for the system
track), with `{audio}` replaced by the path to a mono WAV/M4A file and
`{outdir}` replaced by a scratch output directory it creates and cleans up
per invocation. The engine is expected to write `<audio stem>.json` into
that output directory before exiting 0 — e.g. for `mic.wav` it must write
`mic.json`.

That JSON can take either of these shapes:

- a top-level array of segments:
  ```json
  [{"text": "Hello", "start": 0.1, "end": 0.8}, ...]
  ```
- an object with a `segments` or `sentences` key holding that array (extra
  keys are ignored — this is what `parakeet-mlx --output-format json`
  produces):
  ```json
  {"text": "Hello world.", "sentences": [{"text": "Hello", "start": 0.1, "end": 0.8}, ...]}
  ```

Each segment object needs exactly `text` (string), `start` (seconds,
number), and `end` (seconds, number); extra fields are ignored. If the
engine exits non-zero, or exits 0 but never writes the expected JSON file,
the pipeline stops with that track's stage left at `recorded` and the
engine's full stdout/stderr captured in the session's `pipeline.log` — the
recorded audio is never touched, and `meet process` retries later.

**Plugging in a different engine:** point `stt.command` at any executable
that honors the same `{audio}`/`{outdir}` placeholders and writes JSON in
one of the shapes above. For an engine with a different CLI or output
format, write a small adapter shell script that translates arguments and
reshapes the output, and point `command` at the adapter instead.

## Session storage

Each recording gets its own folder under `recordings_dir`, named by
start time:

```
~/MeetingRecordings/2026-09-03-1420/
├── mic.m4a          # your track, compressed after transcription
├── system.m4a       # their track
├── mic.json         # raw STT segments for the mic track
├── system.json      # raw STT segments for the system track
├── transcript.md    # the assembled, human-readable transcript
├── meta.json         # start/end times, pause intervals, pipeline stage, engine used
└── pipeline.log      # STT engine's captured output, for debugging failures
```

`mic.wav` / `system.wav` exist during and right after recording and are
replaced by the `.m4a` files once transcription succeeds — raw audio is
never deleted before its transcript is safely on disk.

### Pipeline stages

Each session moves through these stages in order, tracked in `meta.json`
so a crash or engine failure always leaves a clear resume point:

1. **recorded** — both WAV tracks are on disk; nothing transcribed yet.
2. **transcribed** — `mic.json` and `system.json` exist (empty `[]` for
   any track that never recorded any audio).
3. **merged** — `transcript.md` has been assembled from the two JSONs.
4. **completed** — WAVs have been compressed to `.m4a` and removed.

`meet process` reads this stage and only does the work that's still
missing; `--force` walks a session through every stage again from
`recorded`, even if it already reached `completed`.
