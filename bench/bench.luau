--!strict
--!native
-- The lab's codecs, timed through their public API over text a compressor finds runs in and
-- noise it finds none in. Run by `jess run --package . bench/bench.luau [filter]` on a release
-- build. Prints one line per workload: its name, a tab, and the seconds one call takes. Every
-- workload's answer is checked against @dream/bytes, before and after it is timed, so a path
-- that stopped doing the work fails here instead of posting a time.
local bytes = require '@dream/bytes'
local codecs = require '@dream/codecs-lab'
local inputs = require '../tests/inputs'

-- A build without the verified toolchain runs Luau slower than a release does, so a number from
-- it says nothing about the code.
if not jess.bench.verified then
  error('codecs bench: this jess was built without the verified toolchain: measure on a release build', 0)
end

local filter: string? = ...
local only = if filter and filter ~= '' then filter else nil

local function median(samples: { number }): number
  table.sort(samples)
  return samples[(#samples + 1) // 2]
end

-- A full collection, run between batches, so one batch's garbage isn't the next one's collection.
local collect = jess.bench.collect

--- Seconds per call of `body`: warmed up, then the median of seven batches of a size that takes
--- about a tenth of a second. `verify` sees the first call's answer and one more after the last
--- batch, outside the time.
local function measure(body: () -> unknown, verify: (result: unknown) -> ()): number
  collect()
  verify(body())

  local start = os.clock()
  body()
  local once = math.max(os.clock() - start, 1e-7)
  local iterations = math.max(1, math.floor(0.1 / once))
  local samples = {}

  for batch = 1, 7 do
    collect()
    start = os.clock()

    for _ = 1, iterations do
      body()
    end

    samples[batch] = (os.clock() - start) / iterations
  end

  verify(body())

  return median(samples)
end

local function workload(name: string, body: () -> unknown, verify: (result: unknown) -> ())
  if only and not string.find(name, only, 1, true) then return end

  print(`{name}\t{string.format('%.9f', measure(body, verify))}`)
end

local function same(expected: buffer): (result: unknown) -> ()
  local spelling = buffer.tostring(expected)

  return function(result: unknown)
    assert(buffer.tostring(result :: buffer) == spelling, 'the answer differs from the input')
  end
end

local Samples = {
  { name = '64 KiB of text', data = inputs.text(65536, 3) },
  { name = '64 KiB of noise', data = inputs.noise(65536, 5) },
  { name = '1 MiB of text', data = inputs.text(1048576, 7) },
}

for _, sample in Samples do
  local data, length = sample.data, buffer.len(sample.data)
  local lz4 = codecs.lz4Compress(data)
  local raw = codecs.rawStoredDeflate(data)
  local zlib = codecs.zlibStoredDeflate(data)

  workload(`lz4Compress, {sample.name}`, function() return codecs.lz4Compress(data) end, function(result)
    assert(buffer.tostring(bytes.lz4Decompress(result :: buffer, length)) == buffer.tostring(data), 'lz4 round trip')
  end)

  workload(`lz4Decompress, {sample.name}`, function() return codecs.lz4Decompress(lz4, length) end, same(data))

  workload(`rawStoredDeflate, {sample.name}`, function() return codecs.rawStoredDeflate(data) end, function(result)
    assert(buffer.tostring(bytes.inflate(result :: buffer, { format = 'raw' })) == buffer.tostring(data), 'raw')
  end)

  workload(`rawStoredInflate, {sample.name}`, function() return codecs.rawStoredInflate(raw) end, same(data))

  workload(`zlibStoredDeflate, {sample.name}`, function() return codecs.zlibStoredDeflate(data) end, same(zlib))
  workload(`zlibStoredDeflateFast, {sample.name}`, function() return codecs.zlibStoredDeflateFast(data) end, same(zlib))
  workload(`zlibStoredInflate, {sample.name}`, function() return codecs.zlibStoredInflate(zlib) end, same(data))
  workload(`zlibStoredInflateFast, {sample.name}`, function() return codecs.zlibStoredInflateFast(zlib) end, same(data))

  workload(`adler32, {sample.name}`, function() return codecs.adler32(data) end, function(result)
    assert(result == bytes.adler32(data), 'adler32')
  end)
end
