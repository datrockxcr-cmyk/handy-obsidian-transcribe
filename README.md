# handy-obsidian-transcribe

Turn a YouTube video or a local video file into an Obsidian-ready Markdown
note: transcript + AI-written title and summary, in one command.

This is a thin glue script. It does not do speech-to-text, summarization, or
note-taking itself — it combines **three** existing tools:

- **[Handy](https://github.com/cjpais/Handy)** — a free, open source,
  offline speech-to-text app. This script uses Handy's `--transcribe-file`
  batch-transcription mode to turn audio into text.
- **[Claude Code](https://github.com/anthropics/claude-code)** (the `claude`
  CLI) — reads the transcript and writes the note's title and summary
  bullets. **This is the step that actually turns a transcript into a
  "note."** Without it, this tool only transcribes — see below.
- **[Obsidian](https://obsidian.md)** — a Markdown-based note-taking app.
  This script writes notes with YAML frontmatter and Obsidian callout syntax
  (`> [!summary]`, `> [!note]-`) designed to be opened in an Obsidian vault.

This project is **not affiliated with Handy, Claude Code/Anthropic, or
Obsidian**. Credit for the actual transcription, summarization, and
note-taking experience belongs to those projects; go check them out.

## What it needs to work

**All three of these are required for the full "transcript → organized
note" workflow.** Missing one doesn't break the script, but it does cut out
a step — see the "Required?" column.

| Tool | Required? | Why |
|---|---|---|
| [Handy](https://github.com/cjpais/Handy) (macOS app) | **Yes, always** | Does the actual speech-to-text. Must be installed, opened once, and have at least one model downloaded via its own GUI before this script can use it headlessly. Without it, nothing in this tool works at all. |
| [Claude Code CLI](https://github.com/anthropics/claude-code) (`claude`), installed and logged in | **Yes, for the note/summary step** | Writes the title and summary. **Without it, the script stops right after transcription and hands you the raw transcript only — no `.md` note is created at all.** This is not a cosmetic extra; it's the "organize into a note" half of what this tool does. |
| [Obsidian](https://obsidian.md) | Recommended | Not a hard dependency — the script just writes `.md` files — but the frontmatter/callout format is meant to be viewed in an Obsidian vault. Point `HANDY_TRANSCRIBE_NOTES_DIR` at a folder inside your vault to get that. |
| [ffmpeg](https://ffmpeg.org) | **Yes** | Converts input audio/video to the 16kHz mono 16-bit PCM WAV Handy's batch mode requires. `brew install ffmpeg` |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Only for YouTube input | Downloads the audio track from a URL. `brew install yt-dlp` |

**Platform: macOS only.** The script quits and relaunches the Handy app
around the batch call (see "How it works" below) using `osascript` /
`open -a`, and assumes Handy's default `.app` install path. Porting the
Handy-lifecycle handling to Windows/Linux is a welcome contribution.

## Install

```bash
git clone <this repo> handy-obsidian-transcribe
cd handy-obsidian-transcribe
chmod +x transcribe.sh
brew install ffmpeg yt-dlp   # yt-dlp only needed for YouTube input
```

Make sure Handy is installed (see its [releases page](https://github.com/cjpais/Handy/releases))
and that you've opened it at least once and downloaded a model from its
Settings screen — this script cannot download a model for you.

Also make sure the [Claude Code](https://claude.com/claude-code) CLI is
installed and logged in (`claude` on your `PATH`, run `claude` once to
confirm it opens). This is what turns the transcript into a title + summary
note — skip it and you'll only get a transcript, not a note.

## Usage

```bash
# YouTube video
./transcribe.sh "https://www.youtube.com/watch?v=xxxx"

# Local video file (any format ffmpeg can read: .mov, .mp4, .mkv, ...)
./transcribe.sh "~/Movies/meeting.mov"

# Override where the note gets written for just this run
./transcribe.sh "~/Movies/meeting.mov" "~/ObsidianVault/Transcripts"
```

By default notes go to `$HOME/HandyTranscripts`. To have them land inside
your actual Obsidian vault every time, set an environment variable (e.g. in
your `~/.zshrc`):

```bash
export HANDY_TRANSCRIBE_NOTES_DIR="$HOME/path/to/YourVault/Transcripts"
```

### Config (all optional environment variables)

| Variable | Default | Purpose |
|---|---|---|
| `HANDY_BIN` | `/Applications/Handy.app/Contents/MacOS/Handy` | Path to the Handy executable |
| `HANDY_TRANSCRIBE_NOTES_DIR` | `$HOME/HandyTranscripts` | Default output folder when the 2nd argument is omitted |
| `HANDY_TRANSCRIBE_TAG` | `transcript` | Frontmatter tag added to every note |
| `HANDY_TRANSCRIBE_LANGUAGE` | `Traditional Chinese` | Language the AI writes the title/summary in |

## How it works

1. **Get the audio.** A URL is downloaded with `yt-dlp` (audio only); a local
   file is used as-is.
2. **Convert it.** `ffmpeg` converts to 16kHz mono 16-bit PCM WAV, the exact
   format Handy's `--transcribe-file` flag requires.
3. **Handle Handy's single-instance app.** If you normally run Handy in the
   background for live dictation, calling its batch-transcription flag while
   it's already running just hangs waiting on the running instance. This
   script quits it first, runs the batch job, then relaunches it — your
   settings and history are untouched.
4. **Transcribe.** Calls `Handy --transcribe-file <wav> --json`, which is an
   undocumented flag found by reading Handy's source — it may change or
   disappear in a future Handy release. If it stops working, check
   `raw/<note>/handy.log` for details.
5. **Summarize.** The transcript is sent to the `claude` CLI with a prompt
   that asks for *only* a JSON object — `{"title": ..., "summary": [...]}`.
   The Markdown structure itself (frontmatter, callouts) is assembled by
   this script, not the model, and the transcript is pasted in verbatim
   rather than asked of the model — this avoids an LLM occasionally dropping
   the closing `---` or silently paraphrasing a long transcript instead of
   reproducing it faithfully.
6. **Write the note.**

## Output

```
<notes dir>/
  2026-08-16 <title>.md          — the note
  raw/
    2026-08-16 <title>/
      transcript.txt              — plain-text transcript backup
      handy.log                   — Handy's stderr output, for debugging
```

The raw audio (`.wav`) is **not** kept — it's converted in a temp directory
that's deleted when the script exits. This is deliberate: if your notes
folder lives inside a git-backed Obsidian vault (e.g. with the
`obsidian-git` plugin auto-committing), large audio files would otherwise
bloat the repository.

Example note:

```markdown
---
date: 2026-08-16
source: youtube
url: "https://www.youtube.com/watch?v=xxxx"
title: Example title
tags:
  - transcript
---

# Example title

> [!summary] Summary
> - key point one
> - key point two

## Transcript

> [!note]- Transcript
> full transcript text goes here, one blockquote line per line of speech
```

## Known limitations

- **Transcription accuracy depends on the Handy model you have selected.**
  Larger Whisper models (e.g. large-v3) are noticeably better than the
  small/default ones, at the cost of speed.
- **Long recordings can be unreliable** with some Handy backends (reports of
  failures past ~8 minutes with ONNX-based models). Prefer a Whisper (ggml)
  model for long videos.
- **`--transcribe-file` is an undocumented flag**, discovered by reading
  Handy's source rather than its docs. Treat it as unstable across Handy
  versions.
- Filenames with unusual whitespace (e.g. a narrow no-break space,
  `U+202F`, which some macOS screen-recording tools insert) won't match a
  manually-typed path — use shell globbing (`*.mov`) or tab-completion
  instead of retyping the name.

## License

MIT — see [LICENSE](LICENSE).
