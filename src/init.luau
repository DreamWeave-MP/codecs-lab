--!strict
--!native
--!optimize 2
local bytes = require '@dream/bytes'

local function trimBuffer(source: buffer, length: number): buffer
  if length == buffer.len(source) then return source end

  return source[1:length]
end

@native
local function writeLength(out: buffer, offset: number, length: number): number
  local remaining = length

  while remaining >= 255 do
    buffer.writeu8(out, offset, 255)
    offset += 1
    remaining -= 255
  end

  buffer.writeu8(out, offset, remaining)
  return offset + 1
end

@native
local function lz4Compress(source: buffer): buffer
  local length = buffer.len(source)
  local capacity = length + math.floor(length / 255) + 32
  local out = buffer.create(capacity)
  local written = 0

  if length < 4 then
    local literalNibble = math.min(length, 15)
    buffer.writeu8(out, written, literalNibble * 16)
    written += 1

    if length >= 15 then written = writeLength(out, written, length - 15) end

    if length > 0 then
      buffer.copy(out, written, source, 0, length)
      written += length
    end

    return trimBuffer(out, written)
  end

  local hashBits = if length < 1024 then 8 elseif length < 16384 then 12 else 16
  local hashSize = bit32.lshift(1, hashBits)
  local hashMask = hashSize - 1
  local hash = buffer.create(hashSize * 4) -- position + 1; zero means empty
  local anchor = 0
  local position = 0
  local limit = length - 4

  while position <= limit do
    local sequence = buffer.readu32(source, position)
    local mixed = bit32.bxor(sequence, bit32.rshift(sequence, 16))
    local slot = bit32.band(mixed * 40543, hashMask)
    local encodedReference = buffer.readu32(hash, slot * 4)
    buffer.writeu32(hash, slot * 4, position + 1)

    local reference = encodedReference - 1

    if
      encodedReference ~= 0
      and position - reference <= 65535
      and buffer.readu32(source, reference) == sequence
    then
      local matchLength = 4
      local maxLength = length - position

      while
        matchLength + 4 <= maxLength
        and buffer.readu32(source, reference + matchLength) == buffer.readu32(source, position + matchLength)
      do
        matchLength += 4
      end

      while
        matchLength < maxLength
        and buffer.readu8(source, reference + matchLength) == buffer.readu8(source, position + matchLength)
      do
        matchLength += 1
      end

      local literalLength = position - anchor
      local matchCode = matchLength - 4
      local literalNibble = math.min(literalLength, 15)
      local matchNibble = math.min(matchCode, 15)
      buffer.writeu8(out, written, literalNibble * 16 + matchNibble)
      written += 1

      if literalLength >= 15 then written = writeLength(out, written, literalLength - 15) end

      if literalLength > 0 then
        buffer.copy(out, written, source, anchor, literalLength)
        written += literalLength
      end

      buffer.writeu16(out, written, position - reference)
      written += 2

      if matchCode >= 15 then written = writeLength(out, written, matchCode - 15) end

      position += matchLength
      anchor = position

      -- Seed the hash near the end of a match so adjacent matches are not lost.
      local insert = position - 2

      if insert >= 0 and insert <= limit then
        local insertSequence = buffer.readu32(source, insert)
        local insertMixed = bit32.bxor(insertSequence, bit32.rshift(insertSequence, 16))
        local insertSlot = bit32.band(insertMixed * 40543, hashMask)
        buffer.writeu32(hash, insertSlot * 4, insert + 1)
      end
    else
      position += 1
    end
  end

  local literalLength = length - anchor
  local literalNibble = math.min(literalLength, 15)
  buffer.writeu8(out, written, literalNibble * 16)
  written += 1

  if literalLength >= 15 then written = writeLength(out, written, literalLength - 15) end

  if literalLength > 0 then
    buffer.copy(out, written, source, anchor, literalLength)
    written += literalLength
  end

  return trimBuffer(out, written)
end

@native
local function lz4Decompress(source: buffer, decompressedSize: number): buffer
  local sourceLength = buffer.len(source)

  -- A block that is one run of literals and nothing else is its own output.
  if sourceLength > 0 then
    local token = buffer.readu8(source, 0)

    if bit32.band(token, 15) == 0 then
      local position = 1
      local literalLength = bit32.rshift(token, 4)

      if literalLength == 15 then
        while position < sourceLength do
          local byte = buffer.readu8(source, position)
          position += 1
          literalLength += byte

          if byte ~= 255 then break end
        end
      end

      if literalLength == decompressedSize and position + literalLength == sourceLength then
        return source[position + 1:position + decompressedSize]
      end
    end
  end

  local out = buffer.create(decompressedSize)
  local position = 0
  local written = 0

  while position < sourceLength do
    local token = buffer.readu8(source, position)
    position += 1

    local literalLength = bit32.rshift(token, 4)

    if literalLength == 15 then
      while true do
        local byte = buffer.readu8(source, position)
        position += 1
        literalLength += byte

        if byte ~= 255 then break end
      end
    end

    if literalLength > 0 then
      buffer.copy(out, written, source, position, literalLength)
      position += literalLength
      written += literalLength
    end

    if position >= sourceLength then break end

    local offset = buffer.readu16(source, position)
    position += 2

    if offset == 0 or offset > written then error('bad lz4 offset', 0) end

    local matchLength = bit32.band(token, 15) + 4

    if bit32.band(token, 15) == 15 then
      while true do
        local byte = buffer.readu8(source, position)
        position += 1
        matchLength += byte

        if byte ~= 255 then break end
      end
    end

    local remaining = matchLength

    while remaining > 0 do
      local chunk = math.min(offset, remaining)
      buffer.copy(out, written, out, written - offset, chunk)
      written += chunk
      remaining -= chunk
    end
  end

  if written ~= decompressedSize then error(`lz4 size mismatch: {written} ~= {decompressedSize}`, 0) end

  return out
end

@native
local function rawStoredDeflate(source: buffer): buffer
  local length = buffer.len(source)
  local blocks = math.max(1, math.ceil(length / 65535))
  local out = buffer.create(length + blocks * 5)
  local position = 0
  local written = 0

  if length == 0 then
    buffer.writeu8(out, 0, 1)
    buffer.writeu16(out, 1, 0)
    buffer.writeu16(out, 3, 65535)
    return out
  end

  while position < length do
    local blockLength = math.min(65535, length - position)
    local final = position + blockLength == length
    buffer.writeu8(out, written, if final then 1 else 0)
    buffer.writeu16(out, written + 1, blockLength)
    buffer.writeu16(out, written + 3, bit32.band(bit32.bnot(blockLength), 0xffff))
    buffer.copy(out, written + 5, source, position, blockLength)
    position += blockLength
    written += blockLength + 5
  end

  return out
end

@native
local function rawStoredInflate(source: buffer): buffer
  local length = buffer.len(source)
  local position = 0
  local total = 0
  local done = false

  while not done do
    if position + 5 > length then error('truncated stored deflate', 0) end

    local header = buffer.readu8(source, position)
    position += 1

    if bit32.band(header, 6) ~= 0 then error('non-stored deflate block', 0) end

    done = bit32.band(header, 1) ~= 0
    local blockLength = buffer.readu16(source, position)
    local inverse = buffer.readu16(source, position + 2)
    position += 4

    if bit32.band(bit32.bnot(blockLength), 0xffff) ~= inverse then error('stored deflate len mismatch', 0) end

    total += blockLength
    position += blockLength

    if position > length then error('truncated stored deflate payload', 0) end
  end

  local out = buffer.create(total)
  local written = 0
  position = 0
  done = false

  while not done do
    local header = buffer.readu8(source, position)
    position += 1
    done = bit32.band(header, 1) ~= 0
    local blockLength = buffer.readu16(source, position)
    position += 4

    if blockLength > 0 then
      buffer.copy(out, written, source, position, blockLength)
      position += blockLength
      written += blockLength
    end
  end

  return out
end

@native
local function adler32(source: buffer): number
  local sum = 1
  local sumOfSums = 0
  local length = buffer.len(source)
  local position = 0

  while position < length do
    local finish = math.min(length, position + 5552)

    while position + 16 <= finish do
      local w0 = buffer.readu32(source, position)
      local w1 = buffer.readu32(source, position + 4)
      local w2 = buffer.readu32(source, position + 8)
      local w3 = buffer.readu32(source, position + 12)
      local x0 = bit32.band(w0, 255)
      local x1 = bit32.band(bit32.rshift(w0, 8), 255)
      local x2 = bit32.band(bit32.rshift(w0, 16), 255)
      local x3 = bit32.rshift(w0, 24)
      local x4 = bit32.band(w1, 255)
      local x5 = bit32.band(bit32.rshift(w1, 8), 255)
      local x6 = bit32.band(bit32.rshift(w1, 16), 255)
      local x7 = bit32.rshift(w1, 24)
      local x8 = bit32.band(w2, 255)
      local x9 = bit32.band(bit32.rshift(w2, 8), 255)
      local x10 = bit32.band(bit32.rshift(w2, 16), 255)
      local x11 = bit32.rshift(w2, 24)
      local x12 = bit32.band(w3, 255)
      local x13 = bit32.band(bit32.rshift(w3, 8), 255)
      local x14 = bit32.band(bit32.rshift(w3, 16), 255)
      local x15 = bit32.rshift(w3, 24)
      sumOfSums += 16 * sum
        + 16 * x0
        + 15 * x1
        + 14 * x2
        + 13 * x3
        + 12 * x4
        + 11 * x5
        + 10 * x6
        + 9 * x7
        + 8 * x8
        + 7 * x9
        + 6 * x10
        + 5 * x11
        + 4 * x12
        + 3 * x13
        + 2 * x14
        + x15
      sum += x0 + x1 + x2 + x3 + x4 + x5 + x6 + x7 + x8 + x9 + x10 + x11 + x12 + x13 + x14 + x15
      position += 16
    end

    while position < finish do
      sum += buffer.readu8(source, position)
      sumOfSums += sum
      position += 1
    end

    sum %= 65521
    sumOfSums %= 65521
  end

  return sumOfSums * 65536 + sum
end

@native
local function zlibStoredDeflate(source: buffer): buffer
  local length = buffer.len(source)
  local blocks = math.max(1, math.ceil(length / 65535))
  local out = buffer.create(2 + length + blocks * 5 + 4)
  buffer.writeu8(out, 0, 0x78)
  buffer.writeu8(out, 1, 0x01)
  local position = 0
  local written = 2

  if length == 0 then
    buffer.writeu8(out, written, 1)
    buffer.writeu16(out, written + 1, 0)
    buffer.writeu16(out, written + 3, 65535)
    written += 5
  else
    while position < length do
      local blockLength = math.min(65535, length - position)
      local final = position + blockLength == length
      buffer.writeu8(out, written, if final then 1 else 0)
      buffer.writeu16(out, written + 1, blockLength)
      buffer.writeu16(out, written + 3, bit32.band(bit32.bnot(blockLength), 0xffff))
      buffer.copy(out, written + 5, source, position, blockLength)
      position += blockLength
      written += blockLength + 5
    end
  end

  local checksum = adler32(source)
  buffer.writeu8(out, written, bit32.band(bit32.rshift(checksum, 24), 255))
  buffer.writeu8(out, written + 1, bit32.band(bit32.rshift(checksum, 16), 255))
  buffer.writeu8(out, written + 2, bit32.band(bit32.rshift(checksum, 8), 255))
  buffer.writeu8(out, written + 3, bit32.band(checksum, 255))
  return out
end

-- Same Luau-owned stored-DEFLATE framing, but delegates only Adler-32 to the
-- native bytes primitive. This is intentionally a narrow hybrid benchmark:
-- Luau owns the codec shape while Rust supplies a checksum primitive.
@native
local function zlibStoredDeflateFast(source: buffer): buffer
  local length = buffer.len(source)
  local blocks = math.max(1, math.ceil(length / 65535))
  local out = buffer.create(2 + length + blocks * 5 + 4)
  buffer.writeu8(out, 0, 0x78)
  buffer.writeu8(out, 1, 0x01)
  local position = 0
  local written = 2

  if length == 0 then
    buffer.writeu8(out, written, 1)
    buffer.writeu16(out, written + 1, 0)
    buffer.writeu16(out, written + 3, 65535)
    written += 5
  else
    while position < length do
      local blockLength = math.min(65535, length - position)
      local final = position + blockLength == length
      buffer.writeu8(out, written, if final then 1 else 0)
      buffer.writeu16(out, written + 1, blockLength)
      buffer.writeu16(out, written + 3, bit32.band(bit32.bnot(blockLength), 0xffff))
      buffer.copy(out, written + 5, source, position, blockLength)
      position += blockLength
      written += blockLength + 5
    end
  end

  local checksum = bytes.adler32(source)
  buffer.writeu8(out, written, bit32.band(bit32.rshift(checksum, 24), 255))
  buffer.writeu8(out, written + 1, bit32.band(bit32.rshift(checksum, 16), 255))
  buffer.writeu8(out, written + 2, bit32.band(bit32.rshift(checksum, 8), 255))
  buffer.writeu8(out, written + 3, bit32.band(checksum, 255))
  return out
end

@native
local function zlibStoredInflate(source: buffer): buffer
  local length = buffer.len(source)

  if length < 11 then error('truncated zlib stream', 0) end

  local method = buffer.readu8(source, 0)
  local flags = buffer.readu8(source, 1)

  if bit32.band(method, 15) ~= 8 or (method * 256 + flags) % 31 ~= 0 or bit32.band(flags, 32) ~= 0 then
    error('unsupported zlib header', 0)
  end

  local position = 2
  local total = 0
  local done = false

  while not done do
    if position + 5 > length - 4 then error('truncated stored zlib', 0) end

    local header = buffer.readu8(source, position)
    position += 1

    if bit32.band(header, 6) ~= 0 then error('non-stored deflate block', 0) end

    done = bit32.band(header, 1) ~= 0
    local blockLength = buffer.readu16(source, position)
    local inverse = buffer.readu16(source, position + 2)
    position += 4

    if bit32.band(bit32.bnot(blockLength), 0xffff) ~= inverse then error('stored deflate len mismatch', 0) end

    total += blockLength
    position += blockLength

    if position > length - 4 then error('truncated stored zlib payload', 0) end
  end

  if position ~= length - 4 then error('unexpected zlib trailer position', 0) end

  local out = buffer.create(total)
  local written = 0
  position = 2
  done = false

  while not done do
    local header = buffer.readu8(source, position)
    position += 1
    done = bit32.band(header, 1) ~= 0
    local blockLength = buffer.readu16(source, position)
    position += 4

    if blockLength > 0 then
      buffer.copy(out, written, source, position, blockLength)
      position += blockLength
      written += blockLength
    end
  end

  local expected = buffer.readu8(source, position) * 16777216
    + buffer.readu8(source, position + 1) * 65536
    + buffer.readu8(source, position + 2) * 256
    + buffer.readu8(source, position + 3)

  if adler32(out) ~= expected then error('zlib adler32 mismatch', 0) end

  return out
end

-- Stored-block decoder with Luau framing/validation and native Adler-32.
-- Useful for small level-0 payloads where generic inflate setup dominates.
@native
local function zlibStoredInflateFast(source: buffer): buffer
  local length = buffer.len(source)

  if length < 11 then error('truncated zlib stream', 0) end

  local method = buffer.readu8(source, 0)
  local flags = buffer.readu8(source, 1)

  if bit32.band(method, 15) ~= 8 or (method * 256 + flags) % 31 ~= 0 or bit32.band(flags, 32) ~= 0 then
    error('unsupported zlib header', 0)
  end

  local position = 2
  local total = 0
  local done = false

  while not done do
    if position + 5 > length - 4 then error('truncated stored zlib', 0) end

    local header = buffer.readu8(source, position)
    position += 1

    if bit32.band(header, 6) ~= 0 then error('non-stored deflate block', 0) end

    done = bit32.band(header, 1) ~= 0
    local blockLength = buffer.readu16(source, position)
    local inverse = buffer.readu16(source, position + 2)
    position += 4

    if bit32.band(bit32.bnot(blockLength), 0xffff) ~= inverse then error('stored deflate len mismatch', 0) end

    total += blockLength
    position += blockLength

    if position > length - 4 then error('truncated stored zlib payload', 0) end
  end

  if position ~= length - 4 then error('unexpected zlib trailer position', 0) end

  local out = buffer.create(total)
  local written = 0
  position = 2
  done = false

  while not done do
    local header = buffer.readu8(source, position)
    position += 1
    done = bit32.band(header, 1) ~= 0
    local blockLength = buffer.readu16(source, position)
    position += 4

    if blockLength > 0 then
      buffer.copy(out, written, source, position, blockLength)
      position += blockLength
      written += blockLength
    end
  end

  local expected = buffer.readu8(source, position) * 16777216
    + buffer.readu8(source, position + 1) * 65536
    + buffer.readu8(source, position + 2) * 256
    + buffer.readu8(source, position + 3)

  if bytes.adler32(out) ~= expected then error('zlib adler32 mismatch', 0) end

  return out
end

return {
  lz4Compress = lz4Compress,
  lz4Decompress = lz4Decompress,
  rawStoredDeflate = rawStoredDeflate,
  rawStoredInflate = rawStoredInflate,
  zlibStoredDeflate = zlibStoredDeflate,
  zlibStoredDeflateFast = zlibStoredDeflateFast,
  zlibStoredInflate = zlibStoredInflate,
  zlibStoredInflateFast = zlibStoredInflateFast,
  adler32 = adler32,
}
