--!strict
-- The lab's codecs against @dream/bytes, which is what they are measured against: every round
-- trip both ways at the lengths where a block, a run or a length byte begins or ends, the
-- checksum against the native one, the refusals, and each function's output pinned by digest to
-- the package as imported.
local bytes = require '@dream/bytes'
local codecs = require '@dream/codecs-lab'
local inputs = require './inputs'
local test = require '@jess/test'

local suite, expect = test.new(), test.expect

local all = inputs.all()

local Pins: { [string]: string } = require './pins'

local function pinned(name: string, value: buffer)
  local found = inputs.digest(value)

  if Pins[name] ~= found then error(`{name}: digest {found}, pinned {Pins[name]}`, 2) end
end

suite.describe('lz4 blocks', function()
  for _, input in all do
    suite.it(`round trip, ours and native, {input.name}`, function()
      local length = buffer.len(input.data)
      local compressed = codecs.lz4Compress(input.data)

      expect(buffer.tostring(codecs.lz4Decompress(compressed, length))).toBe(buffer.tostring(input.data))
      expect(buffer.tostring(bytes.lz4Decompress(compressed, length))).toBe(buffer.tostring(input.data))
      expect(buffer.tostring(codecs.lz4Decompress(bytes.lz4Compress(input.data), length))).toBe(
        buffer.tostring(input.data)
      )
      pinned(`lz4Compress {input.name}`, compressed)
    end)
  end

  suite.it('refuses an offset behind the start', function()
    expect(function() codecs.lz4Decompress(buffer.fromstring '\x10a\x05\x00', 8) end).toThrow 'bad lz4 offset'
  end)

  suite.it('refuses a size it does not reach', function()
    local compressed = codecs.lz4Compress(inputs.text(64, 1))
    expect(function() codecs.lz4Decompress(compressed, 65) end).toThrow 'lz4 size mismatch'
  end)
end)

suite.describe('stored deflate', function()
  for _, input in all do
    suite.it(`raw round trip, ours and native, {input.name}`, function()
      local stored = codecs.rawStoredDeflate(input.data)

      expect(buffer.tostring(codecs.rawStoredInflate(stored))).toBe(buffer.tostring(input.data))
      expect(buffer.tostring(bytes.inflate(stored, { format = 'raw' }))).toBe(buffer.tostring(input.data))
      expect(buffer.tostring(codecs.rawStoredInflate(bytes.deflate(input.data, { format = 'raw', level = 0 })))).toBe(
        buffer.tostring(input.data)
      )
      pinned(`rawStoredDeflate {input.name}`, stored)
    end)

    suite.it(`zlib round trip, both checksums, ours and native, {input.name}`, function()
      local slow, fast = codecs.zlibStoredDeflate(input.data), codecs.zlibStoredDeflateFast(input.data)
      local native = bytes.deflate(input.data, { level = 0 })

      expect(buffer.tostring(fast)).toBe(buffer.tostring(slow))
      expect(buffer.tostring(bytes.inflate(slow))).toBe(buffer.tostring(input.data))

      for _, stream in { slow, native } do
        expect(buffer.tostring(codecs.zlibStoredInflate(stream))).toBe(buffer.tostring(input.data))
        expect(buffer.tostring(codecs.zlibStoredInflateFast(stream))).toBe(buffer.tostring(input.data))
      end

      pinned(`zlibStoredDeflate {input.name}`, slow)
    end)
  end

  suite.it('refuses what it cannot read', function()
    local stored = codecs.zlibStoredDeflate(inputs.text(300, 2))
    local corrupt = buffer.create(buffer.len(stored))
    buffer.copy(corrupt, 0, stored)
    buffer.writeu8(corrupt, buffer.len(corrupt) - 1, (buffer.readu8(corrupt, buffer.len(corrupt) - 1) + 1) % 256)

    expect(function() codecs.zlibStoredInflate(corrupt) end).toThrow 'zlib adler32 mismatch'
    expect(function() codecs.zlibStoredInflateFast(corrupt) end).toThrow 'zlib adler32 mismatch'
    expect(function() codecs.zlibStoredInflate(buffer.fromstring '\x78\x01') end).toThrow 'truncated zlib stream'
    expect(function() codecs.zlibStoredInflate(bytes.deflate(inputs.text(300, 2)) :: buffer) end).toThrow(
      'non-stored deflate block'
    )
    expect(function() codecs.rawStoredInflate(buffer.fromstring '\x01\x05\x00') end).toThrow 'truncated stored deflate'
    expect(function() codecs.rawStoredInflate(buffer.fromstring '\x01\x05\x00\x00\x00') end).toThrow(
      'stored deflate len mismatch'
    )
  end)
end)

suite.describe('adler-32', function()
  for _, input in all do
    suite.it(`matches the native checksum, {input.name}`, function()
      expect(codecs.adler32(input.data)).toBe(bytes.adler32(input.data))
    end)
  end
end)

return suite
