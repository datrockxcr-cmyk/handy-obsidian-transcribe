#!/usr/bin/env bash
# transcribe.sh — turn a YouTube video or a local video file into an
# Obsidian-ready note, using Handy for transcription.
#
#   Handy:    https://github.com/cjpais/Handy    (offline speech-to-text app)
#   Obsidian: https://obsidian.md                (note-taking app / vault format)
#
# This project is not affiliated with either tool. See README.md for credits
# and setup instructions for both.
#
# Usage:
#   ./transcribe.sh <YouTube URL or local video path> [output dir]
#
# Examples:
#   ./transcribe.sh "https://www.youtube.com/watch?v=xxxx"
#   ./transcribe.sh "~/Movies/meeting.mov"
#   ./transcribe.sh "~/Movies/meeting.mov" "~/ObsidianVault/Transcripts"
#
# Config (all optional environment variables):
#   HANDY_BIN                    Path to the Handy executable
#                                 (default: /Applications/Handy.app/Contents/MacOS/Handy)
#   HANDY_TRANSCRIBE_NOTES_DIR   Default output dir when the 2nd argument is
#                                 omitted. Point this at a folder inside your
#                                 Obsidian vault to have notes show up there.
#                                 (default: $HOME/HandyTranscripts)
#   HANDY_TRANSCRIBE_TAG         Frontmatter tag added to every note
#                                 (default: transcript)
#   HANDY_TRANSCRIBE_LANGUAGE    Language the AI writes the title/summary in
#                                 (default: Traditional Chinese)
#
# Requires: ffmpeg, and Handy (macOS app, with a model already downloaded once
# via its GUI — this script cannot download one for you). Optional: yt-dlp
# (for YouTube input) and the Claude Code CLI `claude` (for the AI-written
# title/summary step; without it you still get a plain transcript).
#
# macOS only: relies on Handy's macOS app bundle path and uses `osascript` /
# `open -a` to quit and relaunch it around the batch-transcription call (see
# README.md "How it works" for why).

set -euo pipefail

HANDY_BIN="${HANDY_BIN:-/Applications/Handy.app/Contents/MacOS/Handy}"
DEFAULT_NOTES_DIR="${HANDY_TRANSCRIBE_NOTES_DIR:-$HOME/HandyTranscripts}"
NOTE_TAG="${HANDY_TRANSCRIBE_TAG:-transcript}"
SUMMARY_LANGUAGE="${HANDY_TRANSCRIBE_LANGUAGE:-Traditional Chinese}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <YouTube URL or local video path> [output dir]" >&2
  exit 1
fi

INPUT="$1"
NOTES_DIR="${2:-$DEFAULT_NOTES_DIR}"
RAW_DIR="$NOTES_DIR/raw"
mkdir -p "$NOTES_DIR" "$RAW_DIR"

command -v ffmpeg >/dev/null || { echo "error: ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }
[[ -x "$HANDY_BIN" ]] || { echo "error: Handy executable not found at $HANDY_BIN (set HANDY_BIN to override)" >&2; exit 1; }

WORK="$(mktemp -d /tmp/handy-transcribe.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. Get the source audio ---
SOURCE_URL=""
if [[ "$INPUT" =~ ^https?:// ]]; then
  command -v yt-dlp >/dev/null || { echo "error: yt-dlp not found (brew install yt-dlp)" >&2; exit 1; }
  echo "==> URL detected, downloading audio with yt-dlp..."
  SOURCE_URL="$INPUT"
  SOURCE_TYPE="youtube"
  yt-dlp -f bestaudio -o "$WORK/source.%(ext)s" "$INPUT"
  SRC=$(ls "$WORK"/source.* | head -1)
else
  SRC="${INPUT/#\~/$HOME}"
  [[ -f "$SRC" ]] || { echo "error: file not found: $SRC" >&2; exit 1; }
  SOURCE_TYPE="local"
  echo "==> Using local file: $SRC"
fi

# --- 2. Convert to what Handy's batch mode requires (16kHz / mono / 16-bit PCM WAV) ---
echo "==> Converting audio..."
AUDIO_WAV="$WORK/audio.wav"
ffmpeg -y -loglevel error -i "$SRC" -ar 16000 -ac 1 -c:a pcm_s16le "$AUDIO_WAV"

# --- 3. Handy is a single-instance app. If it's already running in the
#         background (the normal way you use it for dictation), calling
#         --transcribe-file hangs waiting on the running instance. Quit it,
#         run the batch job, then relaunch it exactly as it was. ---
WAS_RUNNING=false
if pgrep -x "handy" >/dev/null 2>&1 || pgrep -f "Handy.app/Contents/MacOS/Handy$" >/dev/null 2>&1; then
  echo "==> Handy is running, quitting it temporarily for batch transcription..."
  osascript -e 'quit app "Handy"' >/dev/null 2>&1 || true
  sleep 2
  pgrep -x "handy" >/dev/null 2>&1 && pkill -x "handy" 2>/dev/null || true
  WAS_RUNNING=true
fi

# --- 4. Call Handy's headless transcription ---
echo "==> Transcribing with Handy (first run loads the model, be patient)..."
RESULT_JSON="$WORK/handy_result.json"
set +e
"$HANDY_BIN" --transcribe-file "$AUDIO_WAV" --json >"$RESULT_JSON" 2>"$WORK/handy.log"
HANDY_EXIT=$?
set -e

if $WAS_RUNNING; then
  echo "==> Relaunching Handy..."
  open -a "Handy" || true
fi

if [[ $HANDY_EXIT -ne 0 ]]; then
  echo "error: Handy transcription failed (exit $HANDY_EXIT), see log below" >&2
  tail -20 "$WORK/handy.log" >&2
  exit 1
fi

TRANSCRIPT="$WORK/transcript.txt"
python3 -c "import json; print(json.load(open('$RESULT_JSON'))['text'])" >"$TRANSCRIPT"
echo "==> Transcription done."

# --- 5. Ask Claude for ONLY a title + summary bullets, as JSON. The
#         Markdown structure (frontmatter, callouts) is assembled by this
#         script, not the model, and the transcript itself is copied in
#         verbatim — this avoids an LLM occasionally dropping the closing
#         `---` or silently paraphrasing a long transcript instead of
#         reproducing it. ---
if ! command -v claude >/dev/null; then
  echo "==> claude CLI not found, skipping the Obsidian note step."
  echo "==> Raw transcript kept at: $TRANSCRIPT"
  exit 0
fi

echo "==> Asking Claude for a title and summary..."
TODAY="$(date +%F)"
AI_RAW="$WORK/ai_raw.txt"
{
cat <<PROMPT
Read the following video transcript and reply with ONLY a JSON object, no
other text, no code fence:
{"title": "a short title, 15 characters or fewer, must not contain / \\ : * ? \" < > |", "summary": ["summary point 1", "summary point 2", "..."]}
Summary points should be 3-6 bullet points covering the key points and
conclusions of the transcript. Do not guess at anything unclear. Write both
the title and summary in $SUMMARY_LANGUAGE.

Transcript:
$(cat "$TRANSCRIPT")
PROMPT
} | claude -p >"$AI_RAW"

TITLE_FILE="$WORK/title.txt"
SUMMARY_FILE="$WORK/summary_lines.txt"
python3 - "$AI_RAW" "$TITLE_FILE" "$SUMMARY_FILE" <<'PY'
import json, re, sys

raw_path, title_path, summary_path = sys.argv[1:4]
raw = open(raw_path, encoding="utf-8").read()
m = re.search(r"\{.*\}", raw, re.S)
data = {}
if m:
    try:
        data = json.loads(m.group(0))
    except Exception:
        data = {}

title = str(data.get("title") or "transcript").strip()
for ch in '/\\:*?"<>|':
    title = title.replace(ch, "_")
title = title[:30] or "transcript"

bullets = data.get("summary") or []
if isinstance(bullets, str):
    bullets = [bullets]

with open(title_path, "w", encoding="utf-8") as f:
    f.write(title)

with open(summary_path, "w", encoding="utf-8") as f:
    if bullets:
        for b in bullets:
            f.write(f"> - {b}\n")
    else:
        f.write("> (the model returned no summary; see the transcript below)\n")
PY

TITLE="$(cat "$TITLE_FILE")"
BASE_NAME="${TODAY} ${TITLE}"

# --- 6. Assemble the note: script-built frontmatter + AI-written summary +
#         the transcript pasted in verbatim ---
NOTE_PATH="$NOTES_DIR/${BASE_NAME}.md"
i=2
while [[ -e "$NOTE_PATH" ]]; do
  NOTE_PATH="$NOTES_DIR/${BASE_NAME} ${i}.md"
  i=$((i + 1))
done

{
  echo "---"
  echo "date: $TODAY"
  echo "source: $SOURCE_TYPE"
  [[ -n "$SOURCE_URL" ]] && echo "url: \"$SOURCE_URL\""
  echo "title: $TITLE"
  echo "tags:"
  echo "  - $NOTE_TAG"
  echo "---"
  echo
  echo "# $TITLE"
  echo
  echo "> [!summary] Summary"
  cat "$SUMMARY_FILE"
  echo
  echo "## Transcript"
  echo
  echo "> [!note]- Transcript"
  sed 's/^/> /' "$TRANSCRIPT"
} >"$NOTE_PATH"

# --- 7. Keep the raw transcript + log next to the note for debugging.
#         Raw audio itself is intentionally not copied anywhere persistent —
#         if NOTES_DIR lives inside a git-backed Obsidian vault (e.g. with
#         the obsidian-git plugin auto-committing), large audio files would
#         otherwise get committed. ---
RAW_SUB="$RAW_DIR/${BASE_NAME}"
mkdir -p "$RAW_SUB"
cp "$TRANSCRIPT" "$RAW_SUB/transcript.txt"
cp "$WORK/handy.log" "$RAW_SUB/handy.log" 2>/dev/null || true

echo "==> Note created: $NOTE_PATH"
echo "==> Raw transcript/log backed up at: $RAW_SUB"
