# Benchmarks

Measured on 2026-10-14 on an Intel Core i7-10870H (2.20 GHz, 8 cores), with a verified release
build of Jess at `b12612f` on l3i 2.0.2.

```sh
jess run --package <package> <package>/bench/bench.luau [filter]
```

Base is `d685040` (the bench's own commit); head is `0cce60d`. Each side ran the whole bench six
times under one lock, base first in odd rounds and head first in even ones, with
`MALLOC_TRIM_THRESHOLD_` and `MALLOC_MMAP_THRESHOLD_` at 1 GiB on both: the megabyte rows
allocate buffers past glibc's trim threshold, and without that they flip between two speeds from
one process to the next. Each figure is the median of the six runs, each run itself the median
of seven batches. Every workload's answer is checked against `@dream/bytes` before and after it
is timed. A difference under 5 percent is noise.

| Workload | Base | Head | Ratio |
|---|---:|---:|---:|
| lz4Compress, 64 KiB of text | 355.2 µs | 354.8 µs | no change |
| lz4Decompress, 64 KiB of text | 258.3 µs | 254.2 µs | no change |
| rawStoredDeflate, 64 KiB of text | 5.2 µs | 5.1 µs | no change |
| rawStoredInflate, 64 KiB of text | 5.2 µs | 5.1 µs | no change |
| zlibStoredDeflate, 64 KiB of text | 114.3 µs | 117.5 µs | no change |
| zlibStoredDeflateFast, 64 KiB of text | 15.3 µs | 15.0 µs | no change |
| zlibStoredInflate, 64 KiB of text | 114.5 µs | 121.0 µs | 0.95x |
| zlibStoredInflateFast, 64 KiB of text | 15.6 µs | 15.3 µs | no change |
| adler32, 64 KiB of text | 108.0 µs | 110.3 µs | no change |
| lz4Compress, 64 KiB of noise | 261.9 µs | 264.0 µs | no change |
| lz4Decompress, 64 KiB of noise | 11.7 µs | 11.7 µs | no change |
| rawStoredDeflate, 64 KiB of noise | 5.4 µs | 5.2 µs | no change |
| rawStoredInflate, 64 KiB of noise | 5.3 µs | 5.1 µs | no change |
| zlibStoredDeflate, 64 KiB of noise | 113.9 µs | 120.8 µs | 0.94x |
| zlibStoredDeflateFast, 64 KiB of noise | 15.3 µs | 15.5 µs | no change |
| zlibStoredInflate, 64 KiB of noise | 113.7 µs | 122.7 µs | 0.93x |
| zlibStoredInflateFast, 64 KiB of noise | 15.7 µs | 15.7 µs | no change |
| adler32, 64 KiB of noise | 107.6 µs | 112.6 µs | no change |
| lz4Compress, 1 MiB of text | 5.426 ms | 5.598 ms | no change |
| lz4Decompress, 1 MiB of text | 4.113 ms | 4.119 ms | no change |
| rawStoredDeflate, 1 MiB of text | 66.7 µs | 64.7 µs | no change |
| rawStoredInflate, 1 MiB of text | 65.9 µs | 64.3 µs | no change |
| zlibStoredDeflate, 1 MiB of text | 1.793 ms | 1.907 ms | 0.94x |
| zlibStoredDeflateFast, 1 MiB of text | 201.0 µs | 198.2 µs | no change |
| zlibStoredInflate, 1 MiB of text | 1.817 ms | 1.961 ms | 0.93x |
| zlibStoredInflateFast, 1 MiB of text | 202.9 µs | 199.2 µs | no change |
| adler32, 1 MiB of text | 1.737 ms | 1.803 ms | no change |

This package is a lab: pure-Luau LZ4, stored DEFLATE and Adler-32, measured against the native
codecs in `@dream/bytes`. What it measures is the Luau, so nothing here was handed to the data
plane: a native Adler-32 already has its own rows (`zlibStoredDeflateFast`,
`zlibStoredInflateFast`), and the other loops already copy with `buffer.copy`. The two manual
sub-buffer copies became buffer slices (`b13ac21`), which the A/B of that commit alone shows as no
change on every row.

Five rows of the pure-Luau zlib paths read 0.93 to 0.95 against base, and they come with the
style cleanup (`0cce60d`), not the slices. That commit renamed locals and spaced statements; it
left `adler32` and `zlibStoredDeflate` instruction for instruction the same in Jess's own
disassembly, and moved one constant load in `zlibStoredInflate`. Run with base and head in a
fixed order, `adler32` itself read 0.93 as well; with the order swapped every round it reads no
change. What is left is where native code lands, not what it does, and it is reported here
rather than traded for the old names.

The suite pins every codec's output for noise and text at each block and length boundary,
round-trips each both ways against `@dream/bytes`, and checks the refusals.
