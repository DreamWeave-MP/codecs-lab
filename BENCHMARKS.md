# Benchmarks

Measured on 2026-10-14 on an Intel Core i7-10870H (2.20 GHz, 8 cores), with a verified release
build of Jess at `b12612f` on l3i 2.0.2.

```sh
jess run --package <package> <package>/bench/bench.jsl [filter]
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

## Which modules are native, and why

Jess compiles to machine code only what is marked (`--!native` on a module, `@native` on one
function), and every load pays for what is marked. A module carries `--!native` when a row below
spends its time there and the module is small (12 KB or less); a larger module carries `@native`
on the functions the row spends its time in, and nothing else.

Measured 2026-10-15 with `jess 0.1.0`, the verified release build of jess `07c38cb` on l3i
2.0.3, on the i7-10870H, the one-minute load 1.38 and 1.40 at the start of the two
sessions. In each session the bench ran alternately on this package and on a copy of it with
every module marked, three fresh runs of `bench/bench.jsl` each, every run's row the median of
its batches; a column is the median of the three, and a ratio is against the all-marked runs of
the same session. Which functions a row spends its time in comes from `jess run --profile` of
that row alone, unmarked. The load cost is a fresh `jess run --package <this package>
--package-path jpk` of a script that only requires `@dream/codecs-lab`, the two sides alternating, the
median of five each after one warm-up.

| Requiring `@dream/codecs-lab` | All marked | This state |
| --- | ---: | ---: |
| Unmarked | 0.051 s | 0.050 s |
| Final | 0.054 s | 0.053 s |

| Row | All marked (ms) | Unmarked / all marked | Final (ms) | Final / all marked |
| --- | ---: | ---: | ---: | ---: |
| lz4Compress, 64 KiB of text | 0.4161 | 1.024× | 0.4110 | 0.988× |
| lz4Decompress, 64 KiB of text | 0.2918 | 1.036× | 0.2754 | 0.944× |
| rawStoredDeflate, 64 KiB of text | 0.00675 | 1.012× | 0.00615 | 0.911× |
| rawStoredInflate, 64 KiB of text | 0.00619 | 1.020× | 0.00602 | 0.973× |
| zlibStoredDeflate, 64 KiB of text | 0.1306 | 0.983× | 0.1266 | 0.969× |
| zlibStoredDeflateFast, 64 KiB of text | 0.03152 | 0.996× | 0.01682 | 0.534× |
| zlibStoredInflate, 64 KiB of text | 0.1329 | 0.996× | 0.1260 | 0.948× |
| zlibStoredInflateFast, 64 KiB of text | 0.01787 | 0.971× | 0.02036 | **1.139×** |
| adler32, 64 KiB of text | 0.1207 | 0.990× | 0.1177 | 0.975× |
| lz4Compress, 64 KiB of noise | 0.3207 | 0.982× | 0.3077 | 0.959× |
| lz4Decompress, 64 KiB of noise | 0.01378 | 0.959× | 0.01315 | 0.955× |
| rawStoredDeflate, 64 KiB of noise | 0.00613 | 0.994× | 0.00608 | 0.992× |
| rawStoredInflate, 64 KiB of noise | 0.00612 | 0.986× | 0.00728 | **1.189×** |
| zlibStoredDeflate, 64 KiB of noise | 0.1270 | 0.999× | 0.1284 | 1.011× |
| zlibStoredDeflateFast, 64 KiB of noise | 0.02009 | 0.993× | 0.01727 | 0.860× |
| zlibStoredInflate, 64 KiB of noise | 0.1268 | 0.992× | 0.1259 | 0.993× |
| zlibStoredInflateFast, 64 KiB of noise | 0.01739 | 0.820× | 0.01802 | 1.036× |
| adler32, 64 KiB of noise | 0.1177 | 0.984× | 0.1153 | 0.979× |
| lz4Compress, 1 MiB of text | 6.117 | 0.976× | 6.107 | 0.998× |
| lz4Decompress, 1 MiB of text | 4.485 | 0.928× | 4.781 | **1.066×** |
| rawStoredDeflate, 1 MiB of text | 0.09622 | 0.936× | 0.09521 | 0.989× |
| rawStoredInflate, 1 MiB of text | 0.1795 | **1.059×** | 0.3269 | **1.821×** |
| zlibStoredDeflate, 1 MiB of text | 2.047 | 1.019× | 2.059 | 1.006× |
| zlibStoredDeflateFast, 1 MiB of text | 0.2668 | 1.006× | 0.2553 | 0.957× |
| zlibStoredInflate, 1 MiB of text | 2.138 | 1.000× | 2.099 | 0.982× |
| zlibStoredInflateFast, 1 MiB of text | 0.3149 | 1.005× | 0.2929 | 0.930× |
| adler32, 1 MiB of text | 2.076 | 0.993× | 1.903 | 0.917× |

What carries the directive: the functions that already carried `@native` before this pass, the
codecs' inner loops, and nothing else:

- `init`, by function: `writeLength`, `lz4Compress`, `lz4Decompress`, `rawStoredDeflate`,
  `rawStoredInflate`, `adler32`, `zlibStoredDeflate`, `zlibStoredDeflateFast`, `zlibStoredInflate`,
  `zlibStoredInflateFast`.

Marking the module whole on top of them bought no row and cost nothing measurable either
(requiring `@dream/codecs-lab` cost 0.0507 s whole and 0.0500 s without). The rows above 5% in
the final session are calls into those same `@native` functions on both sides, and are noise:
`rawStoredInflate, 1 MiB of text` is a copy of a mebibyte whose all-marked runs alone went from
0.13 ms to 0.27 ms, and it read 0.32 ms against 0.34 ms in the session before.
