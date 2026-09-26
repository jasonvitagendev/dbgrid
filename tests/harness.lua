-- Tiny test harness: describe/it/eq with no external dependencies.
local H = { failures = 0, passed = 0, current = "" }

function H.describe(name, fn)
  H.current = name
  fn()
end

function H.it(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    H.passed = H.passed + 1
    io.write("  ok   ", H.current, " / ", name, "\n")
  else
    H.failures = H.failures + 1
    io.write("  FAIL ", H.current, " / ", name, "\n", tostring(err), "\n")
  end
end

function H.eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(
      (msg or "values differ") .. "\n  expected: " .. vim.inspect(expected) .. "\n  actual:   " .. vim.inspect(actual),
      2
    )
  end
end

function H.truthy(v, msg)
  if not v then
    error(msg or ("expected truthy, got " .. vim.inspect(v)), 2)
  end
end

function H.falsy(v, msg)
  if v then
    error(msg or ("expected falsy, got " .. vim.inspect(v)), 2)
  end
end

function H.matches(s, pat, msg)
  if type(s) ~= "string" or not s:find(pat) then
    error((msg or "pattern not found") .. "\n  pattern: " .. pat .. "\n  in: " .. vim.inspect(s), 2)
  end
end

---Wait until fn() is truthy or the timeout passes.
function H.wait(ms, fn)
  return vim.wait(ms, fn, 10)
end

function H.finish()
  io.write(string.format("\n%d passed, %d failed\n", H.passed, H.failures))
  if H.failures > 0 then
    os.exit(1)
  end
end

return H
