--!strict
--!native
--!optimize 2
local bytes = require('@dream/bytes')
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
  local n = buffer.len(source)
  local capacity = n + math.floor(n / 255) + 32
  local out = buffer.create(capacity)
  local outPos = 0

  if n < 4 then
    local literalNibble = math.min(n, 15)
    buffer.writeu8(out, outPos, literalNibble * 16)
    outPos += 1
    if n >= 15 then outPos = writeLength(out, outPos, n - 15) end
    if n > 0 then buffer.copy(out, outPos, source, 0, n); outPos += n end
    return trimBuffer(out, outPos)
  end

  local hashBits = if n < 1024 then 8 elseif n < 16384 then 12 else 16
  local hashSize = bit32.lshift(1, hashBits)
  local hashMask = hashSize - 1
  local hash = buffer.create(hashSize * 4) -- position + 1; zero means empty
  local anchor = 0
  local i = 0
  local limit = n - 4

  while i <= limit do
    local sequence = buffer.readu32(source, i)
    local mixed = bit32.bxor(sequence, bit32.rshift(sequence, 16))
    local h = bit32.band(mixed * 40543, hashMask)
    local encodedRef = buffer.readu32(hash, h * 4)
    buffer.writeu32(hash, h * 4, i + 1)

    local ref = encodedRef - 1
    if encodedRef ~= 0 and i - ref <= 65535 and buffer.readu32(source, ref) == sequence then
      local matchLength = 4
      local maxLength = n - i
      while matchLength + 4 <= maxLength and buffer.readu32(source, ref + matchLength) == buffer.readu32(source, i + matchLength) do
        matchLength += 4
      end
      while matchLength < maxLength and buffer.readu8(source, ref + matchLength) == buffer.readu8(source, i + matchLength) do
        matchLength += 1
      end

      local literalLength = i - anchor
      local matchCode = matchLength - 4
      local literalNibble = math.min(literalLength, 15)
      local matchNibble = math.min(matchCode, 15)
      buffer.writeu8(out, outPos, literalNibble * 16 + matchNibble)
      outPos += 1
      if literalLength >= 15 then outPos = writeLength(out, outPos, literalLength - 15) end
      if literalLength > 0 then
        buffer.copy(out, outPos, source, anchor, literalLength)
        outPos += literalLength
      end

      buffer.writeu16(out, outPos, i - ref)
      outPos += 2
      if matchCode >= 15 then outPos = writeLength(out, outPos, matchCode - 15) end

      i += matchLength
      anchor = i

      -- Seed the hash near the end of a match so adjacent matches are not lost.
      local insert = i - 2
      if insert >= 0 and insert <= limit then
        local seq2 = buffer.readu32(source, insert)
        local mix2 = bit32.bxor(seq2, bit32.rshift(seq2, 16))
        local h2 = bit32.band(mix2 * 40543, hashMask)
        buffer.writeu32(hash, h2 * 4, insert + 1)
      end
    else
      i += 1
    end
  end

  local literalLength = n - anchor
  local literalNibble = math.min(literalLength, 15)
  buffer.writeu8(out, outPos, literalNibble * 16)
  outPos += 1
  if literalLength >= 15 then outPos = writeLength(out, outPos, literalLength - 15) end
  if literalLength > 0 then buffer.copy(out, outPos, source, anchor, literalLength); outPos += literalLength end
  return trimBuffer(out, outPos)
end

@native
local function lz4Decompress(source: buffer, decompressedSize: number): buffer
  local sourceLength = buffer.len(source)
  if sourceLength>0 then
    local token=buffer.readu8(source,0)
    if bit32.band(token,15)==0 then
      local p=1; local literalLength=bit32.rshift(token,4)
      if literalLength==15 then
        while p<sourceLength do local v=buffer.readu8(source,p); p+=1; literalLength+=v; if v~=255 then break end end
      end
      if literalLength==decompressedSize and p+literalLength==sourceLength then
        return source[p + 1:p + decompressedSize]
      end
    end
  end
  local out = buffer.create(decompressedSize)
  local p = 0
  local o = 0

  while p < sourceLength do
    local token = buffer.readu8(source, p)
    p += 1

    local literalLength = bit32.rshift(token, 4)
    if literalLength == 15 then
      while true do
        local v = buffer.readu8(source, p); p += 1; literalLength += v
        if v ~= 255 then break end
      end
    end
    if literalLength > 0 then
      buffer.copy(out, o, source, p, literalLength)
      p += literalLength
      o += literalLength
    end
    if p >= sourceLength then break end

    local offset = buffer.readu16(source, p)
    p += 2
    if offset == 0 or offset > o then error('bad lz4 offset', 0) end

    local matchLength = bit32.band(token, 15) + 4
    if bit32.band(token, 15) == 15 then
      while true do
        local v = buffer.readu8(source, p); p += 1; matchLength += v
        if v ~= 255 then break end
      end
    end

    local remaining = matchLength
    while remaining > 0 do
      local chunk = math.min(offset, remaining)
      buffer.copy(out, o, out, o - offset, chunk)
      o += chunk
      remaining -= chunk
    end
  end

  if o ~= decompressedSize then error(`lz4 size mismatch: {o} ~= {decompressedSize}`, 0) end
  return out
end

@native
local function rawStoredDeflate(source: buffer): buffer
  local n = buffer.len(source)
  local blocks = math.max(1, math.ceil(n / 65535))
  local out = buffer.create(n + blocks * 5)
  local p = 0
  local o = 0
  if n == 0 then
    buffer.writeu8(out, 0, 1); buffer.writeu16(out, 1, 0); buffer.writeu16(out, 3, 65535)
    return out
  end
  while p < n do
    local length = math.min(65535, n - p)
    local final = p + length == n
    buffer.writeu8(out, o, if final then 1 else 0)
    buffer.writeu16(out, o + 1, length)
    buffer.writeu16(out, o + 3, bit32.band(bit32.bnot(length), 0xffff))
    buffer.copy(out, o + 5, source, p, length)
    p += length
    o += length + 5
  end
  return out
end

@native
local function rawStoredInflate(source: buffer): buffer
  local n = buffer.len(source)
  local p = 0
  local total = 0
  local done = false
  while not done do
    if p + 5 > n then error('truncated stored deflate', 0) end
    local header = buffer.readu8(source, p); p += 1
    if bit32.band(header, 6) ~= 0 then error('non-stored deflate block', 0) end
    done = bit32.band(header, 1) ~= 0
    local length = buffer.readu16(source, p)
    local inverse = buffer.readu16(source, p + 2)
    p += 4
    if bit32.band(bit32.bnot(length), 0xffff) ~= inverse then error('stored deflate len mismatch', 0) end
    total += length
    p += length
    if p > n then error('truncated stored deflate payload', 0) end
  end

  local out = buffer.create(total)
  p = 0
  local o = 0
  done = false
  while not done do
    local header = buffer.readu8(source, p); p += 1
    done = bit32.band(header, 1) ~= 0
    local length = buffer.readu16(source, p); p += 4
    if length > 0 then buffer.copy(out, o, source, p, length); p += length; o += length end
  end
  return out
end


@native
local function adler32(source: buffer): number
  local a = 1
  local b = 0
  local n = buffer.len(source)
  local p = 0
  while p < n do
    local finish = math.min(n, p + 5552)
    while p + 16 <= finish do
      local w0 = buffer.readu32(source, p)
      local w1 = buffer.readu32(source, p + 4)
      local w2 = buffer.readu32(source, p + 8)
      local w3 = buffer.readu32(source, p + 12)
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
      b += 16 * a
        + 16*x0 + 15*x1 + 14*x2 + 13*x3
        + 12*x4 + 11*x5 + 10*x6 + 9*x7
        + 8*x8 + 7*x9 + 6*x10 + 5*x11
        + 4*x12 + 3*x13 + 2*x14 + x15
      a += x0+x1+x2+x3+x4+x5+x6+x7+x8+x9+x10+x11+x12+x13+x14+x15
      p += 16
    end
    while p < finish do
      a += buffer.readu8(source, p)
      b += a
      p += 1
    end
    a %= 65521
    b %= 65521
  end
  return b * 65536 + a
end

@native
local function zlibStoredDeflate(source: buffer): buffer
  local n = buffer.len(source)
  local blocks = math.max(1, math.ceil(n / 65535))
  local out = buffer.create(2 + n + blocks * 5 + 4)
  buffer.writeu8(out, 0, 0x78)
  buffer.writeu8(out, 1, 0x01)
  local p = 0
  local o = 2
  if n == 0 then
    buffer.writeu8(out, o, 1); buffer.writeu16(out, o + 1, 0); buffer.writeu16(out, o + 3, 65535); o += 5
  else
    while p < n do
      local length = math.min(65535, n - p)
      local final = p + length == n
      buffer.writeu8(out, o, if final then 1 else 0)
      buffer.writeu16(out, o + 1, length)
      buffer.writeu16(out, o + 3, bit32.band(bit32.bnot(length), 0xffff))
      buffer.copy(out, o + 5, source, p, length)
      p += length
      o += length + 5
    end
  end
  local checksum = adler32(source)
  buffer.writeu8(out, o, bit32.band(bit32.rshift(checksum, 24), 255))
  buffer.writeu8(out, o + 1, bit32.band(bit32.rshift(checksum, 16), 255))
  buffer.writeu8(out, o + 2, bit32.band(bit32.rshift(checksum, 8), 255))
  buffer.writeu8(out, o + 3, bit32.band(checksum, 255))
  return out
end


-- Same Luau-owned stored-DEFLATE framing, but delegates only Adler-32 to the
-- native bytes primitive. This is intentionally a narrow hybrid benchmark:
-- Luau owns the codec shape while Rust supplies a checksum primitive.
@native
local function zlibStoredDeflateFast(source: buffer): buffer
  local n = buffer.len(source)
  local blocks = math.max(1, math.ceil(n / 65535))
  local out = buffer.create(2 + n + blocks * 5 + 4)
  buffer.writeu8(out, 0, 0x78)
  buffer.writeu8(out, 1, 0x01)
  local p = 0
  local o = 2
  if n == 0 then
    buffer.writeu8(out, o, 1); buffer.writeu16(out, o + 1, 0); buffer.writeu16(out, o + 3, 65535); o += 5
  else
    while p < n do
      local length = math.min(65535, n - p)
      local final = p + length == n
      buffer.writeu8(out, o, if final then 1 else 0)
      buffer.writeu16(out, o + 1, length)
      buffer.writeu16(out, o + 3, bit32.band(bit32.bnot(length), 0xffff))
      buffer.copy(out, o + 5, source, p, length)
      p += length
      o += length + 5
    end
  end
  local checksum = bytes.adler32(source)
  buffer.writeu8(out, o, bit32.band(bit32.rshift(checksum, 24), 255))
  buffer.writeu8(out, o + 1, bit32.band(bit32.rshift(checksum, 16), 255))
  buffer.writeu8(out, o + 2, bit32.band(bit32.rshift(checksum, 8), 255))
  buffer.writeu8(out, o + 3, bit32.band(checksum, 255))
  return out
end

@native
local function zlibStoredInflate(source: buffer): buffer
  local n = buffer.len(source)
  if n < 11 then error('truncated zlib stream', 0) end
  local cmf = buffer.readu8(source, 0)
  local flg = buffer.readu8(source, 1)
  if bit32.band(cmf, 15) ~= 8 or (cmf * 256 + flg) % 31 ~= 0 or bit32.band(flg, 32) ~= 0 then error('unsupported zlib header', 0) end
  local p = 2
  local total = 0
  local done = false
  while not done do
    if p + 5 > n - 4 then error('truncated stored zlib', 0) end
    local header = buffer.readu8(source, p); p += 1
    if bit32.band(header, 6) ~= 0 then error('non-stored deflate block', 0) end
    done = bit32.band(header, 1) ~= 0
    local length = buffer.readu16(source, p)
    local inverse = buffer.readu16(source, p + 2)
    p += 4
    if bit32.band(bit32.bnot(length), 0xffff) ~= inverse then error('stored deflate len mismatch', 0) end
    total += length
    p += length
    if p > n - 4 then error('truncated stored zlib payload', 0) end
  end
  if p ~= n - 4 then error('unexpected zlib trailer position', 0) end
  local out = buffer.create(total)
  p = 2
  local o = 0
  done = false
  while not done do
    local header = buffer.readu8(source, p); p += 1
    done = bit32.band(header, 1) ~= 0
    local length = buffer.readu16(source, p); p += 4
    if length > 0 then buffer.copy(out, o, source, p, length); p += length; o += length end
  end
  local expected = buffer.readu8(source,p)*16777216 + buffer.readu8(source,p+1)*65536 + buffer.readu8(source,p+2)*256 + buffer.readu8(source,p+3)
  if adler32(out) ~= expected then error('zlib adler32 mismatch', 0) end
  return out
end


-- Stored-block decoder with Luau framing/validation and native Adler-32.
-- Useful for small level-0 payloads where generic inflate setup dominates.
@native
local function zlibStoredInflateFast(source: buffer): buffer
  local n = buffer.len(source)
  if n < 11 then error('truncated zlib stream', 0) end
  local cmf = buffer.readu8(source, 0)
  local flg = buffer.readu8(source, 1)
  if bit32.band(cmf, 15) ~= 8 or (cmf * 256 + flg) % 31 ~= 0 or bit32.band(flg, 32) ~= 0 then error('unsupported zlib header', 0) end
  local p = 2
  local total = 0
  local done = false
  while not done do
    if p + 5 > n - 4 then error('truncated stored zlib', 0) end
    local header = buffer.readu8(source, p); p += 1
    if bit32.band(header, 6) ~= 0 then error('non-stored deflate block', 0) end
    done = bit32.band(header, 1) ~= 0
    local length = buffer.readu16(source, p)
    local inverse = buffer.readu16(source, p + 2)
    p += 4
    if bit32.band(bit32.bnot(length), 0xffff) ~= inverse then error('stored deflate len mismatch', 0) end
    total += length
    p += length
    if p > n - 4 then error('truncated stored zlib payload', 0) end
  end
  if p ~= n - 4 then error('unexpected zlib trailer position', 0) end
  local out = buffer.create(total)
  p = 2
  local o = 0
  done = false
  while not done do
    local header = buffer.readu8(source, p); p += 1
    done = bit32.band(header, 1) ~= 0
    local length = buffer.readu16(source, p); p += 4
    if length > 0 then buffer.copy(out, o, source, p, length); p += length; o += length end
  end
  local expected = buffer.readu8(source,p)*16777216 + buffer.readu8(source,p+1)*65536 + buffer.readu8(source,p+2)*256 + buffer.readu8(source,p+3)
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
