# codecs-lab

Jess/L3i compression research package. It contains interoperable Luau implementations used to compare generated native Luau against the built-in Rust `@dream/bytes` bindings.

The package deliberately includes both pure-Luau and narrow-hybrid paths:

- LZ4 block compressor/decompressor in Luau.
- Raw DEFLATE stored-block encoder/decoder in Luau.
- Zlib stored-DEFLATE encoder/decoder with pure-Luau Adler-32.
- `zlibStoredDeflateFast`: Luau-owned zlib/stored-DEFLATE framing with only Adler-32 delegated to `@dream/bytes`.
- `zlibStoredInflateFast`: Luau-owned stored-block validation/copy with only Adler-32 delegated to `@dream/bytes`.

This is a benchmark/research package, not a general-purpose replacement for the native compressed codecs. The native LZ4 implementation wins decisively for normal compression. The stored-DEFLATE specializations are interesting because the generic native level-0 zlib path has enough setup overhead that specialized Luau framing can beat it.
