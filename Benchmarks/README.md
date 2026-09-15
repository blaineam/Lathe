# The comparison harness

Generates `RESULTS.md`: Lathe measured against the command-line tools someone
would otherwise reach for, on the same machine, on the same inputs.

```sh
swift run -c release --package-path Benchmarks lathe-bench > Benchmarks/RESULTS.md
```

A **separate package**, depending on Lathe by local path. Nothing here — not the
subprocesses it launches, not its dependency on `LatheMP3` and therefore on LGPL
code — can reach a consumer of the library, and `swift build` in the repository
root does not build any of it.

## The three claims it exists to test

1. **Comparable output.** Where Lathe and a tool use the same library, the files
   should match. A row showing parity is a row doing its job — see WebP, where
   Lathe vendors libwebp and `cwebp` *is* libwebp, and the outputs are the same
   size to the byte.
2. **Faster where hardware exists**, and faster on small work because there is no
   process to launch.
3. **It runs where the tools cannot** — in-process, no subprocess, inside an iOS
   app, inside an App Store build. That is not measurable on a Mac and is stated
   rather than timed.

## Rules, because a table nobody can check is worth nothing

- Same input, same target setting, same output format on both sides.
- **Best of N runs, not the mean.** A mean on a laptop measures what else the
  machine was doing.
- **The tools' process launch is counted.** It is real, and it is exactly what an
  in-process library does not pay. Called out in the notes rather than subtracted
  — a benchmark that quietly discounts its opponent's costs is not one.
- Quality is measured by **ffmpeg** — VMAF for video, SSIM for stills. In those
  rows ffmpeg is the instrument, not a contestant.
- **A size difference is only claimed at matched quality.** Two encoders' "q80"
  are not the same q80. Where the outputs land more than one VMAF point or 0.005
  SSIM apart, the size column says *not matched* and no percentage is printed.
  This cuts in both directions: it is why the JPEG row claims nothing, even
  though Lathe's file is larger, because Lathe's is also visibly better.
- Every version and the machine are printed with the table.
- **Rows Lathe loses are kept.** A table where one side wins everything is not
  believed, and would not be true.

## Energy

`Scripts/measure-energy.sh` measures it with `powermetrics`, which **needs
sudo** — it reads SoC power counters and refuses otherwise. The script asks once
and stores nothing.

```sh
./Benchmarks/Scripts/measure-energy.sh              # 20 s per workload
./Benchmarks/Scripts/measure-energy.sh --seconds 40
```

It measures an idle baseline first and subtracts it, runs each workload in a
loop for a fixed window so there are enough samples to average, and reports
millijoules **per operation**. Short operations are looped rather than timed
once because `powermetrics` averages over an interval: a 700 ms transcode
sampled once is one or two readings of a noisy signal.

### Three things to know before quoting a number from it

1. **Apple calls these estimates.** From `powermetrics --help`, verbatim:
   *"Average power values reported by powermetrics are estimated and may be
   inaccurate — hence they should not be used for any comparison between
   devices, but can be used to help optimize apps for energy efficiency."* A
   against B on one machine is what this is for.
2. **There is no video-encode-engine sampler.** `powermetrics` offers
   `cpu_power`, `gpu_power` and `ane_power`, and nothing for the media engine. A
   hardware HEVC encode happens in a block none of those rails describes. **If
   hardware encoding reads as nearly free, suspect the instrument before
   believing the result** — the script prints every rail it saw, and the sample
   count per rail, so that is checkable rather than assumed.
3. **It measures the machine, not the process.** Close everything else, or a
   browser reindexing in the background lands in the numbers.

### The proxy in the table

The CPU column in `RESULTS.md` is **not** energy, and it *understates* what
hardware costs for exactly the reason in point 2: a fixed-function encoder does
work that never appears as CPU time. A row showing Lathe using 1/295 of the CPU
shows where the work moved, not that it became free.

`proc_pid_rusage`'s `ri_billed_energy` is readable without root and looked like a
way to avoid sudo entirely. It reproduces across runs — hardware HEVC reports
~135,000,000 units against `libx265`'s ~60,000 — and that is three orders of
magnitude in the direction saying *hardware costs more*, which is almost
certainly not what the field means. Its units and sampling are not documented
well enough to publish, so it is recorded here and kept out of the table.

## What the current results say

**Parity where it should be.** WebP: same size to the byte, same SSIM, same
speed. That is the row that makes the rest credible — it shows the harness is
capable of reporting "no difference".

**Large wins where the work is small or the hardware is real.** Probing a file
is ~97× faster than `ffprobe`, because the work is milliseconds and a process
launch is not. Writing metadata is ~7× faster than `exiftool`, which also pays
for a Perl interpreter. HEVC is ~4× faster than `x265` at medium.

**The VP9 row is the best evidence in the table**, because it is the only heavy
row where the two sides land at the *same quality* — 92.16 against 92.13 VMAF,
inside tolerance. At matched quality Lathe's file is 4.8% smaller, arrives 5.9×
sooner, and costs **274× less CPU**. Nothing has to be taken on trust there.

**Losses, kept.** `cjpeg` encodes JPEG twice as fast as ImageIO. `x265` produces
a much smaller file than the hardware encoder — the hardware trades bits for
speed and power, which is the deal it offers. And `cwebp` and `lame` are a hair
faster than Lathe calling the same libraries, which is what "no difference" looks
like when measured honestly.

**AV1 is the row Lathe cannot answer at all.** Its encoder is a spike in a
separate repository and does not ship, because 1.2–1.9 GB of working set is not
a budget an iOS app can plan around. The AV1 row above is ffmpeg's, and it is
there to show what reaching for AV1 costs today rather than to imply Lathe has
an answer.

## What this does not measure

- **Energy.** The interesting claim about hardware encoding is watts, not
  seconds, and `powermetrics` needs root.
- **Real footage.** The fixtures are synthetic: motion and high-frequency detail,
  but no camera noise, no skin, no shallow depth of field, and encoders are tuned
  on footage that has all three.
- **One machine, one resolution, one clip length.**
- **Memory.** Reported for the codec spikes but not here.
