#!/usr/bin/env bash

set -u
set -o pipefail

# ============================================================
# HUBB-E-ISLAM YOUTUBE ARCHIVE
# ============================================================

CHANNEL="https://www.youtube.com/@hubbeislam9263"

BASE_DIR="$HOME/hubb-e-islam"
VIDEOS_DIR="$BASE_DIR/videos"
SHORTS_DIR="$BASE_DIR/shorts"
STATE_DIR="$BASE_DIR/.download-state"

COOKIES="$HOME/cookies.txt"
RCLONE_REMOTE="gdrive:hubb-e-islam"

BATCH_SIZE=100
YTDLP="yt-dlp"
JS_RUNTIME="deno"

# Maximum 480p.
FORMAT='bv*[height<=480][ext=mp4]+ba[ext=m4a]/bv*[height<=480]+ba/b[height<=480][ext=mp4]/b[height<=480]'

# ============================================================
# Directories / state
# ============================================================

mkdir -p "$VIDEOS_DIR" "$SHORTS_DIR" "$STATE_DIR"

VIDEOS_COMPLETED="$STATE_DIR/videos_completed.txt"
SHORTS_COMPLETED="$STATE_DIR/shorts_completed.txt"
VIDEOS_FAILED="$STATE_DIR/videos_failed.txt"
SHORTS_FAILED="$STATE_DIR/shorts_failed.txt"
VIDEO_IDS="$STATE_DIR/video_ids.txt"
SHORT_IDS="$STATE_DIR/short_ids.txt"
LOCKFILE="$STATE_DIR/download.lock"
LOG="$STATE_DIR/downloader.log"

# Temporary stderr files are deliberately kept outside the media folders.
COOKIE_CHECK_LOG="$STATE_DIR/cookie_check.log"
DOWNLOAD_ERROR_LOG="$STATE_DIR/download_error.log"

for file in "$VIDEOS_COMPLETED" "$SHORTS_COMPLETED" "$VIDEOS_FAILED" "$SHORTS_FAILED"; do
    touch "$file"
done

# ============================================================
# Prevent duplicate instances
# ============================================================

exec 9>"$LOCKFILE"

if ! flock -n 9; then
    echo "ERROR: Another archive downloader is already running."
    exit 1
fi

# ============================================================
# Checks
# ============================================================

if [[ ! -f "$COOKIES" ]]; then
    echo "ERROR: Cookies not found:"
    echo "$COOKIES"
    exit 1
fi

if ! command -v "$YTDLP" >/dev/null 2>&1; then
    echo "ERROR: yt-dlp not found."
    exit 1
fi

if ! command -v "$JS_RUNTIME" >/dev/null 2>&1; then
    echo "ERROR: Deno not found."
    echo
    echo "Install with:"
    echo "uv tool install deno"
    exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
    echo "ERROR: rclone not found."
    exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ERROR: ffmpeg not found."
    exit 1
fi

chmod 600 "$COOKIES"

# ============================================================
# Logging
# ============================================================

exec > >(tee -a "$LOG") 2>&1

# ============================================================
# Helpers
# ============================================================

count_lines() {
    local file="$1"
    if [[ -f "$file" ]]; then
        awk 'NF { n++ } END { print n+0 }' "$file"
    else
        echo "0"
    fi
}

is_completed() {
    local id="$1"
    local file="$2"
    grep -Fxq "$id" "$file" 2>/dev/null
}

mark_completed() {
    local id="$1"
    local completed_file="$2"
    local failed_file="$3"

    if ! is_completed "$id" "$completed_file"; then
        printf '%s\n' "$id" >> "$completed_file"
    fi

    if grep -Fxq "$id" "$failed_file" 2>/dev/null; then
        grep -Fxv "$id" "$failed_file" > "${failed_file}.tmp" || true
        mv "${failed_file}.tmp" "$failed_file"
    fi
}

mark_failed() {
    local id="$1"
    local failed_file="$2"

    if ! grep -Fxq "$id" "$failed_file" 2>/dev/null; then
        printf '%s\n' "$id" >> "$failed_file"
    fi
}

free_space() {
    df -h "$BASE_DIR" | awk 'NR==2 {print $4}'
}

# ============================================================
# Cookie/authentication detection
# ============================================================
# yt-dlp can explicitly report that YouTube cookies are no longer valid.
# We also catch the common authentication/bot messages so the script does
# not silently continue for hours with a bad cookie file.

cookies_invalid_in_log() {
    local log_file="$1"

    grep -Eiq \
        'provided .*cookies.*(invalid|expired|no longer valid)|cookies.*(invalid|expired|no longer valid)|sign in to confirm|login required|authentication required|confirm you.?re not a bot|http error 403|unable to access this page' \
        "$log_file" 2>/dev/null
}

abort_for_invalid_cookies() {
    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "COOKIES ARE INVALID / AUTHENTICATION FAILED"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "YouTube rejected the current cookies.txt."
    echo
    echo "PLEASE UPDATE YOUR COOKIES NOW:"
    echo "  $COOKIES"
    echo
    echo "The downloader has stopped so it will NOT keep retrying"
    echo "with invalid cookies. Replace the cookie file and run the"
    echo "script again. Already completed videos/Shorts will still"
    echo "be skipped automatically."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    exit 2
}

check_for_cookie_failure() {
    local log_file="$1"

    if cookies_invalid_in_log "$log_file"; then
        abort_for_invalid_cookies
    fi
}

# ============================================================
# Inventory
# ============================================================

fetch_inventory() {
    echo
    echo "============================================================"
    echo "FETCHING CHANNEL INVENTORY"
    echo "============================================================"

    local tmp_videos="$STATE_DIR/video_ids.tmp"
    local tmp_shorts="$STATE_DIR/short_ids.tmp"
    local video_err="$STATE_DIR/videos_inventory_errors.log"
    local shorts_err="$STATE_DIR/shorts_inventory_errors.log"

    rm -f "$tmp_videos" "$tmp_shorts" "$video_err" "$shorts_err"

    echo
    echo "[1/2] Fetching normal video IDs..."

    "$YTDLP" \
        --cookies "$COOKIES" \
        --js-runtimes "$JS_RUNTIME" \
        --flat-playlist \
        --ignore-errors \
        --print "%(id)s" \
        "$CHANNEL/videos" \
        > "$tmp_videos" 2> "$video_err"

    cat "$video_err" || true
    check_for_cookie_failure "$video_err"

    echo
    echo "[2/2] Fetching Shorts IDs..."

    "$YTDLP" \
        --cookies "$COOKIES" \
        --js-runtimes "$JS_RUNTIME" \
        --flat-playlist \
        --ignore-errors \
        --print "%(id)s" \
        "$CHANNEL/shorts" \
        > "$tmp_shorts" 2> "$shorts_err"

    cat "$shorts_err" || true
    check_for_cookie_failure "$shorts_err"

    # Remove blanks and duplicate IDs.
    sort -u "$tmp_videos" | grep -E '^[A-Za-z0-9_-]{11}$' > "$VIDEO_IDS" || true
    sort -u "$tmp_shorts" | grep -E '^[A-Za-z0-9_-]{11}$' > "$SHORT_IDS" || true

    rm -f "$tmp_videos" "$tmp_shorts"

    local videos="$(count_lines "$VIDEO_IDS")"
    local shorts="$(count_lines "$SHORT_IDS")"
    local vc="$(count_lines "$VIDEOS_COMPLETED")"
    local sc="$(count_lines "$SHORTS_COMPLETED")"

    echo
    echo "============================================================"
    echo "CHANNEL INVENTORY"
    echo "============================================================"
    echo "Videos found:       $videos"
    echo "Shorts found:       $shorts"
    echo "Total:              $((videos + shorts))"
    echo
    echo "Videos completed:   $vc"
    echo "Shorts completed:   $sc"
    echo
    echo "Videos remaining:   $((videos - vc))"
    echo "Shorts remaining:   $((shorts - sc))"
    echo "Total remaining:    $((videos + shorts - vc - sc))"
    echo "============================================================"
}

# ============================================================
# Download one video / Short
# ============================================================

download_one() {
    local id="$1"
    local type="$2"
    local output_dir="$3"
    local completed_file="$4"
    local failed_file="$5"
    local url="https://www.youtube.com/watch?v=$id"

    if is_completed "$id" "$completed_file"; then
        return 0
    fi

    echo
    echo "############################################################"
    echo "DOWNLOADING $type"
    echo "ID:       $id"
    echo "URL:      $url"
    echo "Started:  $(date)"
    echo "Free:     $(free_space)"
    echo "############################################################"
    echo

    rm -f "$DOWNLOAD_ERROR_LOG"

    if "$YTDLP" \
        --cookies "$COOKIES" \
        --js-runtimes "$JS_RUNTIME" \
        --continue \
        --no-overwrites \
        --newline \
        --retries 10 \
        --fragment-retries 10 \
        --file-access-retries 5 \
        --retry-sleep "http:exp=1:30" \
        --retry-sleep "fragment:exp=1:30" \
        --socket-timeout 30 \
        --concurrent-fragments 4 \
        --format "$FORMAT" \
        --merge-output-format mp4 \
        --output "$output_dir/%(title)s [%(id)s].%(ext)s" \
        "$url" 2> >(tee "$DOWNLOAD_ERROR_LOG" >&2)
    then
        check_for_cookie_failure "$DOWNLOAD_ERROR_LOG"

        echo
        echo "------------------------------------------------------------"
        echo "SUCCESS: $type"
        echo "ID: $id"
        echo "Finished: $(date)"
        echo "Free space: $(free_space)"
        echo "------------------------------------------------------------"

        mark_completed "$id" "$completed_file" "$failed_file"
        return 0
    else
        check_for_cookie_failure "$DOWNLOAD_ERROR_LOG"

        echo
        echo "------------------------------------------------------------"
        echo "FAILED: $type"
        echo "ID: $id"
        echo "Time: $(date)"
        echo "------------------------------------------------------------"

        mark_failed "$id" "$failed_file"
        return 1
    fi
}

# ============================================================
# Rclone checkpoint
# ============================================================
# No metadata is uploaded anymore. Only the actual video/Short files
# are copied to Google Drive.

sync_checkpoint() {
    echo
    echo "============================================================"
    echo "RCLONE CHECKPOINT"
    echo "============================================================"
    echo "Remote: $RCLONE_REMOTE"
    echo "Local usage: $(du -sh "$BASE_DIR" 2>/dev/null | awk '{print $1}')"
    echo "Free space:  $(free_space)"
    echo
    echo "Uploading archive media..."
    echo

    if rclone copy \
        "$VIDEOS_DIR" \
        "$RCLONE_REMOTE/videos" \
        --progress \
        --stats=30s \
        --transfers=4 \
        --checkers=8 \
        --retries=5 \
        --low-level-retries=10
    then
        echo "Videos upload completed."
    else
        echo "ERROR: Videos upload failed."
        echo "LOCAL FILES WILL NOT BE DELETED."
        return 1
    fi

    if rclone copy \
        "$SHORTS_DIR" \
        "$RCLONE_REMOTE/shorts" \
        --progress \
        --stats=30s \
        --transfers=4 \
        --checkers=8 \
        --retries=5 \
        --low-level-retries=10
    then
        echo "Shorts upload completed."
    else
        echo "ERROR: Shorts upload failed."
        echo "LOCAL FILES WILL NOT BE DELETED."
        return 1
    fi

    echo
    echo "Verifying remote files..."

    if rclone check "$VIDEOS_DIR" "$RCLONE_REMOTE/videos" --one-way; then
        echo "Videos verification OK."
    else
        echo "ERROR: Videos verification failed."
        return 1
    fi

    if rclone check "$SHORTS_DIR" "$RCLONE_REMOTE/shorts" --one-way; then
        echo "Shorts verification OK."
    else
        echo "ERROR: Shorts verification failed."
        return 1
    fi

    echo
    echo "Remote verification successful."
    echo
    echo "Removing local downloaded media..."

    find "$VIDEOS_DIR" \
        -type f \
        \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' -o -iname '*.m4a' \) \
        -delete

    find "$SHORTS_DIR" \
        -type f \
        \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' -o -iname '*.m4a' \) \
        -delete

    find "$VIDEOS_DIR" "$SHORTS_DIR" -type d -empty -delete 2>/dev/null || true

    echo
    echo "Local media cleaned."
    echo "Free space now: $(free_space)"
    echo "============================================================"
}

# ============================================================
# Trap
# ============================================================

on_exit() {
    local code=$?
    echo
    echo "============================================================"
    echo "ARCHIVE PROCESS STOPPED"
    echo "Time: $(date)"
    echo "Exit code: $code"
    echo "============================================================"
}

trap on_exit EXIT

# ============================================================
# Header
# ============================================================

echo
echo "============================================================"
echo "        HUBB-E-ISLAM YOUTUBE ARCHIVE"
echo "============================================================"
echo "Started:        $(date)"
echo "Channel:        $CHANNEL"
echo
echo "Videos:         $VIDEOS_DIR"
echo "Shorts:         $SHORTS_DIR"
echo "Google Drive:   $RCLONE_REMOTE"
echo "Batch size:     $BATCH_SIZE"
echo "Format:         <= 480p"
echo "JS runtime:     $JS_RUNTIME"
echo "Metadata:       DISABLED"
echo "============================================================"
echo

# ============================================================
# Inventory
# ============================================================

fetch_inventory

TOTAL_VIDEOS="$(count_lines "$VIDEO_IDS")"
TOTAL_SHORTS="$(count_lines "$SHORT_IDS")"
DONE_VIDEOS="$(count_lines "$VIDEOS_COMPLETED")"
DONE_SHORTS="$(count_lines "$SHORTS_COMPLETED")"

echo
echo "Starting archive:"
echo "  Videos remaining: $((TOTAL_VIDEOS - DONE_VIDEOS))"
echo "  Shorts remaining: $((TOTAL_SHORTS - DONE_SHORTS))"
echo "  Metadata downloads: DISABLED"
echo

# ============================================================
# Download videos
# ============================================================

BATCH_COUNTER=0
CURRENT=0

echo
echo "============================================================"
echo "DOWNLOADING NORMAL VIDEOS"
echo "============================================================"

while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    CURRENT=$((CURRENT + 1))

    if is_completed "$id" "$VIDEOS_COMPLETED"; then
        echo "[$CURRENT/$TOTAL_VIDEOS] SKIP video $id — already completed"
        continue
    fi

    if download_one \
        "$id" \
        "VIDEO [$CURRENT/$TOTAL_VIDEOS]" \
        "$VIDEOS_DIR" \
        "$VIDEOS_COMPLETED" \
        "$VIDEOS_FAILED"
    then
        BATCH_COUNTER=$((BATCH_COUNTER + 1))
    fi

    if (( BATCH_COUNTER >= BATCH_SIZE )); then
        BATCH_COUNTER=0
        sync_checkpoint
    fi
done < "$VIDEO_IDS"

# ============================================================
# Download Shorts
# ============================================================

CURRENT=0

echo
echo "============================================================"
echo "DOWNLOADING SHORTS"
echo "============================================================"

while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    CURRENT=$((CURRENT + 1))

    if is_completed "$id" "$SHORTS_COMPLETED"; then
        echo "[$CURRENT/$TOTAL_SHORTS] SKIP Short $id — already completed"
        continue
    fi

    if download_one \
        "$id" \
        "SHORT [$CURRENT/$TOTAL_SHORTS]" \
        "$SHORTS_DIR" \
        "$SHORTS_COMPLETED" \
        "$SHORTS_FAILED"
    then
        BATCH_COUNTER=$((BATCH_COUNTER + 1))
    fi

    if (( BATCH_COUNTER >= BATCH_SIZE )); then
        BATCH_COUNTER=0
        sync_checkpoint
    fi
done < "$SHORT_IDS"

# ============================================================
# Final summary
# ============================================================

DONE_VIDEOS="$(count_lines "$VIDEOS_COMPLETED")"
DONE_SHORTS="$(count_lines "$SHORTS_COMPLETED")"
FAILED_VIDEOS="$(count_lines "$VIDEOS_FAILED")"
FAILED_SHORTS="$(count_lines "$SHORTS_FAILED")"

echo
echo "============================================================"
echo "DOWNLOAD PASS COMPLETE"
echo "============================================================"
echo "Videos:"
echo "  Found:       $TOTAL_VIDEOS"
echo "  Completed:   $DONE_VIDEOS"
echo "  Failed:      $FAILED_VIDEOS"
echo
echo "Shorts:"
echo "  Found:       $TOTAL_SHORTS"
echo "  Completed:   $DONE_SHORTS"
echo "  Failed:      $FAILED_SHORTS"
echo
echo "Total completed: $((DONE_VIDEOS + DONE_SHORTS))"
echo "Total failed:    $((FAILED_VIDEOS + FAILED_SHORTS))"
echo "Free space:      $(free_space)"
echo "============================================================"

# ============================================================
# Final upload
# ============================================================

sync_checkpoint

echo
echo "============================================================"
echo "                 ALL DONE"
echo "============================================================"
echo "Finished: $(date)"
echo "============================================================"
