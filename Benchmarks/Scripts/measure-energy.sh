#!/bin/bash
#
# Measures the energy a workload costs, using `powermetrics`.
#
#   ./Benchmarks/Scripts/measure-energy.sh
#   ./Benchmarks/Scripts/measure-energy.sh --seconds 30
#
# **Needs sudo**, and there is no way around that: `powermetrics` reads SoC
# power counters and refuses to run otherwise. The script asks once, up front,
# and never stores anything.
#
# ────────────────────────────────────────────────────────────────────────────
#  READ THIS BEFORE QUOTING ANY NUMBER THIS PRINTS
# ────────────────────────────────────────────────────────────────────────────
#
# 1. **Apple says these are estimates.** `powermetrics --help`, verbatim:
#    "Average power values reported by powermetrics are estimated and may be
#    inaccurate - hence they should not be used for any comparison between
#    devices, but can be used to help optimize apps for energy efficiency."
#    So: A against B on ONE machine is what this is for. A number from this
#    machine against a number from another machine is not a comparison.
#
# 2. **There is no video-encode-engine sampler.** powermetrics offers
#    `cpu_power`, `gpu_power` and `ane_power` and nothing for the media engine.
#    A hardware H.264/HEVC encode happens in a block none of those rails
#    describes. If the SoC's package total does not absorb it, hardware encoding
#    will read as nearly free here — and that would be a gap in the instrument,
#    not a fact about the encoder. The script prints every power line it saw so
#    that this is checkable rather than assumed; if hardware HEVC comes out at
#    baseline while doing real work, disbelieve the number.
#
# 3. **The baseline is subtracted, and it matters.** An idle Mac is not a zero
#    reading. Without subtracting it, every workload inherits the machine's
#    floor and short cheap operations look far more expensive than they are.
#
# 4. **Close everything else.** This measures the machine, not the process.
#    A browser reindexing in the background lands in the numbers.
set -euo pipefail

SECONDS_PER_CASE=20
INTERVAL_MS=100
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="$HERE/.build/release/lathe-bench"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_PER_CASE="$2"; shift 2 ;;
        --interval) INTERVAL_MS="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ ! -x "$BENCH" ]; then
    echo "building lathe-bench…" >&2
    swift build -c release --package-path "$HERE" >&2
    BENCH="$(swift build -c release --package-path "$HERE" --show-bin-path)/lathe-bench"
fi

echo "This needs sudo to read the SoC power counters. Asking once." >&2
sudo -v

# Keep the credential alive for the whole run rather than re-prompting in the
# middle of a measurement, which would show up as a gap in the samples.
( while true; do sudo -n true; sleep 30; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null || true; rm -rf "$WORK"' EXIT

# ── Sampling ────────────────────────────────────────────────────────────────

# Runs a command while sampling, and prints the mean power of each rail.
sample() {
    local label="$1"; shift
    local log="$WORK/$label.txt"

    sudo powermetrics --samplers cpu_power,gpu_power,ane_power \
        -i "$INTERVAL_MS" -o "$log" >/dev/null 2>&1 &
    local pm=$!
    sleep 0.6                       # let the first sample land before work starts

    local result
    result="$("$@" 2>/dev/null || true)"

    sleep 0.3
    sudo kill -INT "$pm" 2>/dev/null || true
    wait "$pm" 2>/dev/null || true

    # Every "<Something> Power: N mW" line, averaged per rail. Parsed rather than
    # cherry-picked so a rail that exists on some machines and not others shows
    # up instead of being silently absent.
    python3 - "$log" "$label" "$result" <<'PY'
import re, sys
path, label, result = sys.argv[1], sys.argv[2], sys.argv[3]
rails = {}
for line in open(path, errors="ignore"):
    # The combined rail is spelled "Combined Power (CPU + GPU + ANE): N mW",
    # so the parenthetical has to be allowed for or the one line the report
    # keys on is silently dropped and every energy figure reads as zero.
    m = re.match(r"\s*(.+?)\s*Power(?:\s*\([^)]*\))?:\s*([0-9.]+)\s*mW", line)
    if m:
        rails.setdefault(m.group(1).strip(), []).append(float(m.group(2)))
print(f"{label}\t{result}\t" + ";".join(
    f"{name}={sum(v)/len(v):.1f}:{len(v)}" for name, v in sorted(rails.items())
))
PY
}

echo >&2
echo "measuring an idle baseline for ${SECONDS_PER_CASE}s…" >&2
# `sleep`, not a loop in our own binary. The baseline has to be the machine
# doing nothing, and the cheapest way to be sure of that is to run something
# that provably does nothing.
BASELINE="$(sample idle sleep "$SECONDS_PER_CASE")"

# What the machine was ACTUALLY doing during that window. A contaminated
# baseline is the single easiest way to get a whole table of plausible-looking
# wrong numbers, and it is invisible unless you look.
echo >&2
echo "busiest processes during the baseline:" >&2
ps -Ao %cpu,comm -r 2>/dev/null | head -6 | sed 's/^/  /' >&2
LOAD="$(uptime | sed 's/.*load averages*: //' | awk '{print $1}')"
echo "  load average: $LOAD" >&2

CASES=(
    "lathe-hevc|$BENCH|--loop|hevc|$SECONDS_PER_CASE"
    "lathe-webp|$BENCH|--loop|webp|$SECONDS_PER_CASE"
)

RESULTS=("$BASELINE")
for entry in "${CASES[@]}"; do
    IFS='|' read -r name cmd a b c <<< "$entry"
    echo "measuring $name for ${SECONDS_PER_CASE}s…" >&2
    RESULTS+=("$(sample "$name" "$cmd" "$a" "$b" "$c")")
done

# ffmpeg, both encoders, driven for the same wall time so the comparison is like
# for like rather than one long run against many short ones.
SRC="$(ls "${TMPDIR:-/tmp}"/lathe-bench/source-5s.mov 2>/dev/null || true)"
if [ -n "$SRC" ] && command -v ffmpeg >/dev/null; then
    for pair in "ffmpeg-hevc-hw:-hwaccel videotoolbox -c:v hevc_videotoolbox -q:v 55" \
                "ffmpeg-hevc-sw:-c:v libx265 -preset medium -crf 26"; do
        name="${pair%%:*}"; args="${pair#*:}"
        echo "measuring $name for ${SECONDS_PER_CASE}s…" >&2
        RESULTS+=("$(sample "$name" bash -c "
            end=\$(( \$(date +%s) + $SECONDS_PER_CASE )); n=0
            while [ \$(date +%s) -lt \$end ]; do
                ffmpeg -nostdin -y -loglevel error $args -i '$SRC' '$WORK/out.mp4' || break
                n=\$((n+1))
            done
            echo \$n")")
    done
fi

# ── Report ──────────────────────────────────────────────────────────────────

# The rows go to a FILE, not a pipe. `python3 - <<EOF` already takes its script
# from stdin, so piping data in as well means the script is read as the data and
# the report sees nothing — it printed "no samples" and looked like a sudo or
# powermetrics failure rather than the plumbing mistake it was.
printf '%s\n' "${RESULTS[@]}" > "$WORK/rows.tsv"
python3 - "$SECONDS_PER_CASE" "$WORK/rows.tsv" <<'PY'
import sys

window = float(sys.argv[1])
rows = []
for line in open(sys.argv[2]):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 3:
        continue
    label, iterations, rails = parts[0], parts[1].strip(), parts[2]
    parsed = {}
    for entry in rails.split(";"):
        if not entry or "=" not in entry:
            continue
        name, rest = entry.split("=", 1)
        mean, count = rest.split(":")
        parsed[name] = (float(mean), int(count))
    rows.append((label, iterations, parsed))

if not rows:
    print("no samples — powermetrics produced nothing. Was sudo granted?")
    raise SystemExit(1)

baseline = rows[0][2]
rail_names = sorted({name for _, _, rails in rows for name in rails})

print()
print("| workload | iterations | " + " | ".join(f"{n} (mW)" for n in rail_names)
      + " | energy above idle | per operation |")
# Four fixed columns — workload, iterations, energy, per operation — plus one
# per rail. Off by one and every renderer draws the table wrong.
print("|---" * (4 + len(rail_names)) + "|")

for label, iterations, rails in rows:
    cells = []
    above = 0.0
    for name in rail_names:
        mean = rails.get(name, (0.0, 0))[0]
        cells.append(f"{mean:.0f}")
        # Only the combined rail is totalled, or CPU+GPU+ANE would be counted
        # twice on machines that report both the parts and the sum.
        if "Combined" in name:
            above = max(0.0, mean - baseline.get(name, (0.0, 0))[0])
    if above == 0.0:
        for name in rail_names:
            if "Combined" in name:
                continue
            above += max(0.0, rails.get(name, (0.0, 0))[0] - baseline.get(name, (0.0, 0))[0])

    joules = above / 1000.0 * window
    try:
        count = int(iterations)
    except ValueError:
        count = 0
    per = f"{joules / count * 1000:.1f} mJ" if count > 0 and label != "idle" else "—"
    energy = "— (baseline)" if label == "idle" else f"{joules:.1f} J"
    print(f"| {label} | {iterations or '—'} | " + " | ".join(cells)
          + f" | {energy} | {per} |")

# A quiet Apple-silicon Mac idles in the hundreds of milliwatts. Anything near a
# watt means something else was running, and every row below inherits it —
# "energy above idle" is only meaningful if idle was idle.
idle_combined = 0.0
for name, (mean, _) in baseline.items():
    if "Combined" in name:
        idle_combined = mean
if idle_combined > 3000:
    print()
    print(f"> **These numbers are not usable.** The idle baseline measured "
          f"{idle_combined:.0f} mW. A quiet Apple-silicon Mac idles in the "
          f"hundreds of milliwatts, so something else was running throughout — "
          f"and every row above inherits it. Close other applications, wait for "
          f"Spotlight and any file-provider sync to settle, check `uptime` shows "
          f"a low load average, and run it again.")
    print(">")
    print("> The *ratios* between workloads survive a contaminated baseline "
          "better than the absolute figures do, because every row was measured "
          "under the same contamination — but do not publish the joules.")

print()
print("Energy above idle = (mean combined power − idle combined power) × window.")
print("Per operation divides that by how many times the workload completed.")
print()
print("Sample counts per rail, so a thin sample is visible rather than hidden:")
for label, _, rails in rows:
    counts = ", ".join(f"{n}×{c}" for n, (_, c) in sorted(rails.items()))
    print(f"  {label}: {counts}")
PY

cat >&2 <<'NOTE'

Reminders before this number leaves the room:
  * Estimates, per Apple, and only valid A-against-B on THIS machine.
  * No media-engine rail exists. If hardware encoding reads as nearly free,
    suspect the instrument before believing the result.
  * Idle baseline subtracted; close other applications or you measure them too.
NOTE
