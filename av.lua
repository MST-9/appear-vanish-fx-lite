-- Appear & Vanish FX core. Pure Lua, integer maths only. Every output pixel is a copy of a source pixel, except the
-- optional edge colour (one value taken from the sprite's own colours). Images are {w=,h=,d={}} with 0 = transparent.
local M = {}
function M.new(w, h) local d = {} for i = 1, w * h do d[i] = 0 end return { w = w, h = h, d = d } end
function M.get(im, x, y) if x < 0 or y < 0 or x >= im.w or y >= im.h then return 0 end return im.d[y * im.w + x + 1] end
function M.set(im, x, y, v) if x >= 0 and y >= 0 and x < im.w and y < im.h then im.d[y * im.w + x + 1] = v end end
function M.clone(im) local o = M.new(im.w, im.h) for i = 1, #im.d do o.d[i] = im.d[i] end return o end

function M.bbox(im)
  local x0, y0, x1, y1 = math.huge, math.huge, -1, -1
  for y = 0, im.h - 1 do for x = 0, im.w - 1 do
    if im.d[y * im.w + x + 1] ~= 0 then
      if x < x0 then x0 = x end; if x > x1 then x1 = x end; if y < y0 then y0 = y end; if y > y1 then y1 = y end
    end
  end end
  if x1 < 0 then return nil end
  return x0, y0, x1, y1
end

local B2 = { { 0, 2 }, { 3, 1 } }
-- Bayer value of (x, y) for a 2^levels matrix: a permutation of 0 .. 4^levels - 1 per tile.
function M.bayer(x, y, levels)
  local v = 0
  for l = 0, levels - 1 do v = v * 4 + B2[((y >> l) & 1) + 1][((x >> l) & 1) + 1] end
  return v
end

-- Seeded permutation of the box cells: rank of cell (x, y) in 0 .. A-1. Deterministic for a given seed.
local function make_perm(box, seed)
  local bw, bh = box.x1 - box.x0 + 1, box.y1 - box.y0 + 1
  local A = bw * bh
  local p = {}
  for i = 1, A do p[i] = i - 1 end
  local s = ((seed or 1) * 2654435761 + 12345) & 0x7fffffff
  for i = A, 2, -1 do
    s = (s * 1103515245 + 12345) & 0x7fffffff
    local j = (s >> 8) % i + 1
    p[i], p[j] = p[j], p[i]
  end
  return { bw = bw, A = A, p = p }
end

local function dither_frame(im, c, n, o)
  local levels = (o.bayer == 8) and 3 or 2
  local B = 4 ^ levels | 0
  local out = M.new(im.w, im.h)
  for y = 0, im.h - 1 do for x = 0, im.w - 1 do
    local v = im.d[y * im.w + x + 1]
    if v ~= 0 and M.bayer(x, y, levels) * n < B * c then out.d[y * im.w + x + 1] = v end
  end end
  return out
end

local function scatter_frame(im, c, n, o)
  local box = o.box
  if not o._perm then o._perm = make_perm(box, o.seed) end
  local pm = o._perm
  local out = M.new(im.w, im.h)
  for y = box.y0, box.y1 do for x = box.x0, box.x1 do
    local v = M.get(im, x, y)
    if v ~= 0 then
      local r = pm.p[(y - box.y0) * pm.bw + (x - box.x0) + 1]
      if r * n < pm.A * c then M.set(out, x, y, v) end
    end
  end end
  return out
end

-- Wipe: reveal count of rows/columns of the box. Returns the image and a leading-edge predicate position list.
local function wipe_frame(im, c, n, o, rows_from_bottom_only)
  local box = o.box
  local dir = o.dir or "tb"
  local vertical = (dir == "tb" or dir == "bt")
  local L = vertical and (box.y1 - box.y0 + 1) or (box.x1 - box.x0 + 1)
  local r = L * c // n
  local out = M.new(im.w, im.h)
  local edge = {}
  for y = 0, im.h - 1 do for x = 0, im.w - 1 do
    local v = im.d[y * im.w + x + 1]
    if v ~= 0 then
      local t
      if dir == "tb" then t = y - box.y0 elseif dir == "bt" then t = box.y1 - y
      elseif dir == "lr" then t = x - box.x0 else t = box.x1 - x end
      if t < r then
        out.d[y * im.w + x + 1] = v
        if t == r - 1 then edge[#edge + 1] = y * im.w + x + 1 end
      end
    end
  end end
  return out, edge
end

-- Materialise: reveal from the bottom up (beam) while the width squashes in around the box centre.
local function materialise_frame(im, c, n, o)
  local box = o.box
  local W, L = box.x1 - box.x0 + 1, box.y1 - box.y0 + 1
  local wk = math.max(1, (W * (n + 2 * c)) // (3 * n))
  local nx0 = box.x0 + (W - wk) // 2
  local r = L * c // n
  local out = M.new(im.w, im.h)
  local edge = {}
  for y = box.y0, box.y1 do
    local t = box.y1 - y
    if t < r then
      for x = nx0, nx0 + wk - 1 do
        local v = M.get(im, box.x0 + ((x - nx0) * W) // wk, y)
        if v ~= 0 then
          M.set(out, x, y, v)
          if t == r - 1 then edge[#edge + 1] = y * im.w + x + 1 end
        end
      end
    end
  end
  return out, edge
end

-- One frame at coverage step c (0 = empty ... n = the source). Edge colour only on 0 < c < n.
function M.frame(im, effect, c, n, o)
  if c <= 0 then return M.new(im.w, im.h) end
  if c >= n then return M.clone(im) end
  if not o.box then
    local x0, y0, x1, y1 = M.bbox(im)
    if not x0 then return M.new(im.w, im.h) end
    o.box = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
  end
  local out, edge
  if effect == "dither" then out = dither_frame(im, c, n, o)
  elseif effect == "scatter" then out = scatter_frame(im, c, n, o)
  elseif effect == "wipe" then out, edge = wipe_frame(im, c, n, o)
  elseif effect == "materialise" then out, edge = materialise_frame(im, c, n, o)
  else error("unknown effect " .. tostring(effect)) end
  if o.ev and edge then for _, i in ipairs(edge) do out.d[i] = o.ev end end
  return out
end

-- n frames. mode "appear": coverage 1..n (last == source). "vanish": n-1..0 (last empty).
-- ghost: faint every-second-pixel afterimage of the previous frame, on all but the last frame.
function M.sequence(im, effect, mode, n, o)
  local seq = {}
  for k = 1, n do
    local c = (mode == "appear") and k or (n - k)
    seq[k] = M.frame(im, effect, c, n, o)
  end
  if o.ghost then
    local res = {}
    for k = 1, n do
      local f = M.clone(seq[k])
      if k < n then
        local prev = (k > 1) and seq[k - 1] or nil
        if prev then
          for y = 0, f.h - 1 do for x = 0, f.w - 1 do
            local i = y * f.w + x + 1
            if f.d[i] == 0 and prev.d[i] ~= 0 and (x + y + k) % 2 == 0 then f.d[i] = prev.d[i] end
          end end
        end
      end
      res[k] = f
    end
    seq = res
  end
  return seq
end

return M
