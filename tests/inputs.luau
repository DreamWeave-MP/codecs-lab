--!strict
-- What the suite and the bench feed the codecs: noise a compressor finds nothing in and text it
-- finds runs in, at the lengths where a block, a run or a length byte begins or ends; and the
-- digest the suite pins each output by.
local bytes = require '@dream/bytes'

local Inputs = {}

export type Input = { name: string, data: buffer }

Inputs.Lengths = { 0, 1, 3, 4, 5, 14, 15, 16, 19, 254, 255, 256, 270, 5552, 5553, 65535, 65536, 70000 }

--- Bytes a compressor finds nothing in: a linear congruential stream from a seed.
function Inputs.noise(length: number, seed: number): buffer
  local out = buffer.create(length)
  local state = seed

  for index = 0, length - 1 do
    state = (state * 1103515245 + 12345) % 2147483648
    buffer.writeu8(out, index, state // 65536 % 256)
  end

  return out
end

--- Bytes with runs and repeats in them: words from a short list, picked by the same stream.
function Inputs.text(length: number, seed: number): buffer
  local words = { 'Morrowind ', 'Vvardenfell ', 'Balmora ', 'silt strider ', 'Dagoth Ur ', 'netch ' }
  local out = buffer.create(length)
  local state, written = seed, 0

  while written < length do
    state = (state * 1103515245 + 12345) % 2147483648
    local word = words[state // 65536 % #words + 1]
    local count = math.min(#word, length - written)
    buffer.writestring(out, written, word, count)
    written += count
  end

  return out
end

--- The first sixteen hex digits of the BLAKE3 of a buffer.
function Inputs.digest(value: buffer): string
  return string.sub(bytes.blake3(buffer.tostring(value)), 1, 16)
end

--- Every input the suite runs, noise and text at each length, and a long run of zeros.
function Inputs.all(): { Input }
  local all: { Input } = {}

  for _, length in Inputs.Lengths do
    table.insert(all, { name = `{length} bytes of noise`, data = Inputs.noise(length, length + 7) })
    table.insert(all, { name = `{length} bytes of text`, data = Inputs.text(length, length + 11) })
  end

  table.insert(all, { name = '70000 zero bytes', data = buffer.create(70000) })

  return all
end

return Inputs
