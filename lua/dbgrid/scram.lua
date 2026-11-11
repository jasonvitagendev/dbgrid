-- SCRAM-SHA-256 password verifiers, the form PostgreSQL stores in pg_authid and
-- accepts in `ALTER ROLE ... PASSWORD '<verifier>'` (what psql's \password sends).
-- Hashing here keeps the clear-text password out of the statement, so it cannot
-- reach the server log, pg_stat_statements or a monitoring agent's query samples.
local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, lshift, ror, tobit = bit.rshift, bit.lshift, bit.ror, bit.tobit
local unpack = unpack or table.unpack

local M = {}

M.ITERATIONS = 4096 -- PostgreSQL's default scram_iterations
local SALT_LEN = 16

-- stylua: ignore
local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function be32(n)
  return string.char(band(rshift(n, 24), 255), band(rshift(n, 16), 255), band(rshift(n, 8), 255), band(n, 255))
end

---@param msg string
---@return string digest  32 raw bytes
function M.sha256(msg)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local len = #msg
  local pad = (55 - len) % 64
  msg = msg .. "\128" .. string.rep("\0", pad) .. "\0\0\0\0" .. be32(len * 8)
  local w = {}
  for i = 1, #msg, 64 do
    for j = 0, 15 do
      local a, b, c, d = msg:byte(i + j * 4, i + j * 4 + 3)
      w[j] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    end
    for j = 16, 63 do
      local x, y = w[j - 15], w[j - 2]
      local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
      local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
      w[j] = tobit(w[j - 16] + s0 + w[j - 7] + s1)
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for j = 0, 63 do
      local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = tobit(h + s1 + ch + K[j + 1] + w[j])
      local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local t2 = tobit(s0 + maj)
      h, g, f, e, d, c, b, a = g, f, e, tobit(d + t1), c, b, a, tobit(t1 + t2)
    end
    h0, h1, h2, h3 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d)
    h4, h5, h6, h7 = tobit(h4 + e), tobit(h5 + f), tobit(h6 + g), tobit(h7 + h)
  end
  return be32(h0) .. be32(h1) .. be32(h2) .. be32(h3) .. be32(h4) .. be32(h5) .. be32(h6) .. be32(h7)
end

local function xor_pad(key, byte)
  local out = {}
  for i = 1, 64 do
    out[i] = string.char(bxor(key:byte(i) or 0, byte))
  end
  return table.concat(out)
end

---@param key string
---@param msg string
---@return string mac  32 raw bytes
function M.hmac(key, msg)
  if #key > 64 then
    key = M.sha256(key)
  end
  return M.sha256(xor_pad(key, 0x5c) .. M.sha256(xor_pad(key, 0x36) .. msg))
end

---PBKDF2-HMAC-SHA256 with a 32-byte result (one block, all SCRAM needs).
---@param password string
---@param salt string
---@param iterations integer
---@return string
function M.pbkdf2(password, salt, iterations)
  if #password > 64 then
    password = M.sha256(password)
  end
  local ipad, opad = xor_pad(password, 0x36), xor_pad(password, 0x5c)
  local u = M.sha256(opad .. M.sha256(ipad .. salt .. "\0\0\0\1"))
  local acc = { u:byte(1, 32) }
  for _ = 2, iterations do
    u = M.sha256(opad .. M.sha256(ipad .. u))
    for i = 1, 32 do
      acc[i] = bxor(acc[i], u:byte(i))
    end
  end
  return string.char(unpack(acc))
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

---@param s string
---@return string
function M.base64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = lshift(a, 16) + lshift(b or 0, 8) + (c or 0)
    local i1, i2 = rshift(n, 18) + 1, band(rshift(n, 12), 63) + 1
    local i3, i4 = band(rshift(n, 6), 63) + 1, band(n, 63) + 1
    out[#out + 1] = B64:sub(i1, i1)
      .. B64:sub(i2, i2)
      .. (b and B64:sub(i3, i3) or "=")
      .. (c and B64:sub(i4, i4) or "=")
  end
  return table.concat(out)
end

---Random salt from the OS generator.
---@return string? salt, string? err
local function random_salt()
  local uv = vim.uv or vim.loop
  if uv and uv.random then
    local ok, bytes = pcall(uv.random, SALT_LEN)
    if ok and type(bytes) == "string" and #bytes == SALT_LEN then
      return bytes
    end
  end
  local f = io.open("/dev/urandom", "rb")
  local bytes = f and f:read(SALT_LEN)
  if f then
    f:close()
  end
  if bytes and #bytes == SALT_LEN then
    return bytes
  end
  return nil, "no source of random bytes for the salt"
end

---The verifier of a password: `SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>`.
---Only printable ASCII passwords: anything else needs SASLprep first, which the
---server applies at login, and a verifier of the unprepared bytes would not match.
---@param password string
---@param opts? { salt?: string, iterations?: integer }
---@return string? verifier, string? err
function M.verifier(password, opts)
  opts = opts or {}
  if type(password) ~= "string" or password == "" then
    return nil, "empty password"
  end
  if password:find("[^\32-\126]") then
    return nil, "the password has characters outside printable ASCII (not supported for a SCRAM verifier)"
  end
  local salt, err = opts.salt, nil
  if not salt then
    salt, err = random_salt()
    if not salt then
      return nil, err
    end
  end
  local iterations = opts.iterations or M.ITERATIONS
  local salted = M.pbkdf2(password, salt, iterations)
  local stored_key = M.sha256(M.hmac(salted, "Client Key"))
  local server_key = M.hmac(salted, "Server Key")
  return ("SCRAM-SHA-256$%d:%s$%s:%s"):format(iterations, M.base64(salt), M.base64(stored_key), M.base64(server_key))
end

return M
