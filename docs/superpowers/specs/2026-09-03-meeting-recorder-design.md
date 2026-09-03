# Meeting Recorder — Design

Date: 2026-09-03
Status: approved for planning

## Overview

A macOS utility that records a call (microphone + system audio as two separate
tracks, without interfering with the audio stream) and produces a transcript
via a local, pluggable speech-to-text engine. The current engine is
`parakeet-mlx` (model `parakeet-tdt-0.6b-v3`, multilingual — calls mix Russian
and English within a single meeting); the engine must be replaceable without
recompiling the app.

The tool is a personal utility, shared with colleagues at most, but the
repository is written entirely in English with future publication in mind.

### Goals

- One-key start/stop recording of mic + system audio; playback and the call
  itself are never interrupted or rerouted (no virtual audio devices).
- Batch transcription after the call; no streaming pipeline.
- Transcript distinguishes "me" (mic track) from "them" (system track) for
  free, by construction.
- STT engine is an external command described in config — swapping engines is
  a one-line change.
- Recorded audio survives any downstream failure; every pipeline stage can be
  re-run.

### Non-goals (now; some are future slots)

- Real-time / streaming transcription — explicitly not wanted.
- Automatic meeting detection — manual start only.
- Speaker diarization within the system track — future stage slot (see
  Pipeline stages), not implemented now.
- Calendar integration — future; would only enrich `meta.json`.
- Menu bar app — future third target on top of the same core library.
- Per-application capture — whole-system capture is sufficient (Core Audio
  taps keep the door open).
- Summaries / LLM post-processing — the user feeds `transcript.md` to their
  own AI tooling.

## Architecture

One Swift Package, two targets (a third, the menu bar app, may come later):

- **`MeetKit`** — core library: audio capture, pipeline orchestration,
  transcript assembly. No UI, no CLI knowledge.
- **`meet`** — CLI executable, a thin wrapper over MeetKit providing the
  interactive terminal UI.

### Capture

Two independent writers run during a recording session:

1. **Microphone** — `AVAudioEngine` input node → `mic.wav`.
2. **System audio** — Core Audio process tap (macOS 14.2+ API) on the whole
   system output → `system.wav`. The tap listens post-mix; nothing is
   rerouted, Zoom/Meet/Teams/Slack keep playing untouched.

Both tracks are mono PCM WAV, 48 kHz, written to disk continuously. WAV is
deliberate: if the process dies mid-call, everything written so far is
readable (unlike an unfinalized m4a), and parakeet consumes WAV directly.
The cost (~350 MB/hour/track) is reclaimed after successful transcription:
tracks are compressed to `mic.m4a` / `system.m4a` and the WAVs deleted. The
m4a files are kept permanently — archive plus material for future diarization.

Track sync: both writers start from the same code point; the tens-of-ms skew
is irrelevant at sentence granularity. Exact per-track start timestamps are
recorded in `meta.json` regardless.

Device changes mid-call (e.g. plugging in headphones) are handled: both the
tap and the mic input reattach to the new default device. This is a known
Core Audio pain point and is designed in from the start.

Permissions (microphone, system audio recording) are checked before the
first recording starts, with an actionable message pointing to the right
System Settings pane — never a silent recording of nothing.

### Process model & interactive controls

`meet` is a long-lived interactive program. Recording sessions come and go
within one run; transcription runs in the background (it loads the GPU,
while recording is lightweight audio I/O — they don't compete).

Single-key controls, no command input:

| Key | Action |
| --- | --- |
| `z` | Start/stop recording. On stop, the session goes to background transcription; a new recording can start immediately. |
| `space` | Pause/resume recording. Pause stops writing to the WAVs; resume appends. Pause intervals are stored in `meta.json`; transcript timecodes are audio-time. |
| `q` | Quit: stops an active recording like `z`, waits for all background transcriptions, exits. |
| `Ctrl+C` | Safety net, equivalent to `q`. A second `Ctrl+C` exits immediately (track files are already intact; transcription can be caught up later with `meet process`). |

Status line reflects both planes, e.g.:

```
● rec 00:12:34  mic ✓  system ✓ | transcribing: 2026-09-03-1420 (2/2)
idle | transcribing: 2026-09-03-1420 (1/2)
```

If one writer fails mid-recording (e.g. a headset drops), the other track
keeps recording and the status line shows `mic ✗` immediately.

### STT contract

The STT engine is an **external command described in config**, never a
compiled-in dependency:

```toml
[stt]
command = "parakeet-mlx {audio} --output-format json --output-dir {outdir}"
```

Contract: the command receives a WAV path (`{audio}`) and must place into
`{outdir}` a JSON file with segments `{text, start, end}` — exactly what
`parakeet-mlx` already emits. Swapping engines = swapping the line, provided
the new engine (or a thin adapter script around it) emits the same JSON
shape. MeetKit knows only the JSON format.

Tracks are transcribed **sequentially** (one, then the other): two parallel
instances of a 0.6b model would fight over GPU memory rather than speed
things up, and parakeet on Apple Silicon runs many times faster than
real time anyway.

Mixed-language calls are the model's concern (parakeet v3 auto-detects
language per utterance); MeetKit does not interfere.

### Pipeline stages & storage

Each session is a folder:

```
~/MeetingRecordings/2026-09-03-1420/
├── mic.m4a          # my track (compressed after transcription)
├── system.m4a       # their track
├── mic.json         # raw STT segments per track
├── system.json
├── transcript.md    # final output
└── meta.json        # start timestamps, duration, pause intervals,
                     # per-stage status, engine version
```

Stages: `recorded` → `transcribed` → `merged` (then compression). Each
stage's status lives in `meta.json`, so after any failure it is visible where
to resume.

**Transcript assembly** is a pure function: two segment JSONs → markdown.
Segments are merged into one chronology by `start`; the mic track is labeled
with `speaker_me`, the system track with `speaker_them`. Consecutive segments
from the same speaker with a gap under `merge_gap_seconds` (default 2.0) are
merged into one utterance so the text doesn't shatter into interjections.

```markdown
# Call 2026-09-03 14:20 (52 min)

**[00:00:03] Them:** Hi Greg, can you hear me?
**[00:00:06] Me:** Yes, loud and clear...
```

Flat markdown by design: equally convenient for hand-editing meeting minutes
and for feeding whole into an AI tool.

Raw JSONs stay on disk so that: (a) re-assembly never requires
re-transcription; (b) future diarization is a stage that rewrites
`system.json` (splitting "Them" into "Them 1/2") followed by re-assembly —
no other component changes.

### Error handling principles

**Audio is worth more than everything else.** No downstream failure may lose
recorded audio.

- STT failure (engine crash, missing model, disk full): WAVs are kept, stage
  status stays `recorded`, the engine's full output goes to a per-session log.
- `meet process` (below) catches up any unfinished stages.
- Permission problems are reported before recording, not discovered after.

## CLI

Two commands:

```bash
meet
```
The interactive mode described above. Started once, lives in a terminal
corner all day.

```bash
meet process <folder> | --all [--force]
```
Catch-up mode: reads per-stage status from `meta.json` and completes
whatever is unfinished (transcription, assembly, compression). `--all` walks
the whole recordings dir. `--force` redoes even completed stages — the
"changed engines, redo an old call" path.

No list/view/delete commands: session folders are self-describing in Finder
and `ls`.

## Config

`~/.config/meet/config.toml`, entirely optional — defaults work without it:

```toml
recordings_dir = "~/MeetingRecordings"

[stt]
command = "parakeet-mlx {audio} --output-format json --output-dir {outdir}"

[transcript]
merge_gap_seconds = 2.0   # same-speaker gap below which utterances merge
speaker_me = "Me"
speaker_them = "Them"
```

No audio settings are exposed (sample rate, format are internal constants):
until there is a reason to tune them, they are only a surface for mistakes.

## Testing

- Transcript assembly and JSON parsing are pure functions → unit tests:
  utterance merging, overlapping timecodes, an empty track (silent
  counterpart), pause-interval timecode math.
- The STT contract is tested with a fake engine script, proving the config
  swap truly has no hidden dependencies.
- Capture is verified manually/integration-style; automating it costs more
  than it protects.

## Known trade-offs

- Running the CLI from a terminal attributes microphone / system-audio TCC
  permissions to the terminal app (or Claude Code). Acceptable for a personal
  tool; a future menu bar app owns its permissions properly.
- WAV-during-recording doubles temporary disk usage until compression; chosen
  deliberately for crash-safety.
