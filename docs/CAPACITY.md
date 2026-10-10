# Capacity: what iClear can and cannot change

## What macOS already does

macOS keeps memory full on purpose and manages pressure by itself: it compresses
inactive pages in memory (the compressor) and, when that is not enough, writes them to
swap on the SSD. Apps that sit idle without waking are compressed and swapped anyway,
paused or not.

## What iClear changes

A background app that keeps waking (timers, sync, rendering) keeps touching its memory,
so macOS cannot compress or swap it cheaply and has to bring pages back again. Pausing
such an app stops that: the kernel can compress or swap its memory once and leave it
there until you switch back. Nothing is freed or deleted; the app keeps its windows and
state. Thrash Guard (off by default) applies the same pause to background apps that cause
page-in storms.

## What it cannot change

- Physical memory, SSD speed, the compressor's settings, or how macOS decides pressure.
- Root-owned processes and daemons (for example Spotlight `mds`, `backupd`): iClear does
  not pause them.
- Apps you are using: the frontmost app and apps with visible windows are not paused.
- Workloads where the apps that hold memory do not wake: then there is no gain to measure.

## SSD wear

Pausing does not write anything by itself. If paused apps are swapped out, macOS writes
their pages to the SSD, as it would under pressure anyway; how much depends on your apps
and memory. iClear does not measure SSD wear.

## `iclear capacity`

Shows, for the last 7 days: the number of pause episodes, the paused footprint and time,
regrets (apps you brought back within 10 minutes), the measured change in available
memory (free + inactive + speculative + purgeable) 60 seconds after the last pause of
each episode, as a median and 25th-75th percentile, and how many episodes gained nothing;
an estimate of the headroom before pressure turns warning, with an interval from the
warning onsets it has seen; and swap in use with its change over 24 hours. With no
episodes it says there is nothing to report. `--json` gives the same numbers.

The change in available memory is a measurement on your Mac, not a promise: other apps
start, stop and allocate in the same minute. Lab results with N and distributions will
be in [VALIDATION.md](VALIDATION.md) once the capacity benchmark has run (stage 6 of
[RELEASE_CRITERIA_v1.1.md](RELEASE_CRITERIA_v1.1.md)); none is published yet.
