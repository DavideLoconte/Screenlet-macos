#!/bin/sh
# Measures latency and fidelity for each codec and priority on a test pattern:
#   ./bench.sh [cable|wifi] [seconds]
# The installed app shows the pattern on the tablet with each setting in turn.
# The tablet reports the time from capture to decoded, with its clock matched
# to the Mac's. The Mac decodes its own stream and compares it with the
# captured frames (luma PSNR, dB). Keep Screenlet open and the tablet awake.
# The first seconds of each run, with the start and its keyframe, are skipped.
set -e
how="${1:-cable}"
seconds="${2:-20}"
log="$HOME/Library/Logs/Screenlet.log"
echo "| codec | priority | median ms | 90% ms | fps | lost | kbit/s | PSNR dB | lowest dB |"
echo "|---|---|---|---|---|---|---|---|---|"
for codec in h264 hevc; do
    for priority in latency balanced clarity; do
        mark=$(wc -l < "$log")
        open -n -W -a "Screenlet" --args --show-"$how" "$seconds" pattern measure "$priority" "$codec"
        tail -n +$((mark + 1)) "$log" | grep "app display: .* fps" | tail -n +3 | awk -v codec="$codec" -v priority="$priority" '
            {
                for (i = 1; i <= NF; i++) {
                    if ($(i+1) == "fps,") fps += $i
                    if ($i == "lost") lost += $(i+1)
                    if ($i == "decoded" && $(i+1) ~ /^[0-9.]+$/ && !seen) { median += $(i+1); seen = 1 }
                    if ($i == "(90%:") p90 += $(i+1)
                    if ($(i+1) ~ /^kbit\/s/) kbps += $i
                    if ($i == "PSNR") { psnr += $(i+1); n++ }
                    if ($i == "(lowest" && (lows == 0 || $(i+1) + 0 < low)) { low = $(i+1) + 0; lows++ }
                }
                seen = 0; rows++
            }
            END {
                if (!rows) { printf "| %s | %s | (no reports) |\n", codec, priority; exit }
                mean = n ? sprintf("%.1f", psnr / n) : "?"
                lowest = lows ? sprintf("%.1f", low) : "?"
                printf "| %s | %s | %.1f | %.1f | %.0f | %d | %.0f | %s | %s |\n", codec, priority, median / rows, p90 / rows,
                       fps / rows, lost, kbps / rows, mean, lowest
            }'
    done
done
