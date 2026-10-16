-- Appear & Vanish FX -- Aseprite extension entry point.
-- The pixel maths live in av.lua; this file reads cels, builds the new frames and writes the tags.

local core = nil
local LITE = true -- the Lite build flips this to true (see build_bundles.py)

local function load_core(dir)
  if not core then core = dofile(app.fs.joinPath(dir, "av.lua")) end
  return core
end

-- Cel -> sprite-sized core image (0 = transparent). Indexed colours are stored as index+1.
local function cel_to_core(spr, cel)
  local S = core
  local im = S.new(spr.width, spr.height)
  local px = app.pixelColor
  local mode, tc = spr.colorMode, spr.transparentColor
  local cx, cy = cel.position.x, cel.position.y
  for it in cel.image:pixels() do
    local v = it()
    local x, y = it.x + cx, it.y + cy
    if mode == ColorMode.INDEXED then
      if v ~= tc then S.set(im, x, y, v + 1) end
    elseif mode == ColorMode.GRAY then
      if px.grayaA(v) > 0 then S.set(im, x, y, v) end
    else
      if px.rgbaA(v) > 0 then S.set(im, x, y, v) end
    end
  end
  return im
end

local function core_to_image(spr, im)
  local img = Image(im.w, im.h, spr.colorMode)
  local indexed = spr.colorMode == ColorMode.INDEXED
  if indexed then img:clear(spr.transparentColor) end
  for y = 0, im.h - 1 do for x = 0, im.w - 1 do
    local v = im.d[y * im.w + x + 1]
    if v ~= 0 then img:drawPixel(x, y, indexed and (v - 1) or v) end
  end end
  return img
end

-- The sprite's own lightest colour as a core value (used for the 1-px leading edge). Never a new colour.
local function lightest(spr, srcs)
  local px = app.pixelColor
  local mode = spr.colorMode
  local pal = spr.palettes[1]
  local best, bv = -1, nil
  for _, s in ipairs(srcs) do
    for _, v in ipairs(s.im.d) do
      if v ~= 0 then
        local lum
        if mode == ColorMode.INDEXED then
          local pc = pal:getColor(v - 1); lum = pc.red * 30 + pc.green * 59 + pc.blue * 11
        elseif mode == ColorMode.GRAY then lum = px.grayaV and px.grayaV(v) or (v & 0xff)
        else lum = px.rgbaR(v) * 30 + px.rgbaG(v) * 59 + px.rgbaB(v) * 11 end
        if lum > best then best, bv = lum, v end
      end
    end
  end
  return bv
end

local function collect_layers(parent, out)
  for _, l in ipairs(parent.layers) do
    if l.isGroup then collect_layers(l, out)
    elseif l.isVisible then out[#out + 1] = l end
  end
end

-- plan: list of { mode = "appear"|"vanish" }. opts: effect, n, bayer, dir, edge, seed, ghost.
-- Builds every segment as new frames after frame fn, one tag per segment. Returns frames created or nil, message.
local function generate(spr, layer, fn, plan, o, all_layers, duration)
  local S = core
  local layers = {}
  if all_layers then collect_layers(spr, layers) else layers[1] = layer end
  local src = {}
  local bx0, by0, bx1, by1 = math.huge, math.huge, -1, -1
  for _, l in ipairs(layers) do
    local c = l:cel(fn)
    if c then
      local im = cel_to_core(spr, c)
      local x0, y0, x1, y1 = S.bbox(im)
      if x0 then
        bx0, by0, bx1, by1 = math.min(bx0, x0), math.min(by0, y0), math.max(bx1, x1), math.max(by1, y1)
        src[#src + 1] = { layer = l, im = im }
      end
    end
  end
  if #src == 0 then return nil, "The selected frame has no drawing on this layer." end
  local ev = o.edge and lightest(spr, src) or nil
  local made = 0
  app.transaction("Appear & Vanish FX", function()
    local cur = fn
    for _, seg in ipairs(plan) do
      local per = {}
      for i, s in ipairs(src) do
        per[i] = S.sequence(s.im, o.effect, seg.mode, o.n, {
          bayer = o.bayer, dir = o.dir, ev = ev, seed = o.seed, ghost = o.ghost,
          box = { x0 = bx0, y0 = by0, x1 = bx1, y1 = by1 } })
      end
      local first = cur + 1
      for k = 1, o.n do
        local nf = spr:newFrame(cur)
        nf.duration = duration / 1000
        for i, s in ipairs(src) do
          spr:newCel(s.layer, cur + 1, core_to_image(spr, per[i][k]), Point(0, 0))
        end
        cur = cur + 1
        made = made + 1
      end
      local tag = spr:newTag(first, cur)
      tag.name = seg.mode
    end
  end)
  return made
end

local EFFECTS = { "Dither fade", "Scanline wipe", "Scatter reveal", "Materialise (teleport)" }
local EFFECT_OF = { ["Dither fade"] = "dither", ["Scanline wipe"] = "wipe", ["Scatter reveal"] = "scatter",
                    ["Materialise (teleport)"] = "materialise" }
local DIRS = { ["Top to bottom"] = "tb", ["Bottom to top"] = "bt", ["Left to right"] = "lr", ["Right to left"] = "rl" }

local function show_dialog(plugin)
  local spr = app.sprite
  if not spr then app.alert("Open a sprite first."); return end
  local layer = app.layer
  if not layer or layer.isGroup then app.alert("Select a normal layer first."); return end
  load_core(plugin.path)
  local prefs = plugin.preferences
  local title = LITE and "Appear & Vanish FX (Lite)" or "Appear & Vanish FX"
  local dlg = Dialog(title)
  if LITE then
    dlg:label { text = "Dither fade in and out: 6 frames each, tagged appear and vanish." }
  else
    dlg:combobox { id = "effect", label = "Effect", option = prefs.effect or "Dither fade", options = EFFECTS }
    dlg:combobox { id = "mode", label = "Make", option = prefs.mode or "Appear and vanish", options = { "Appear and vanish", "Appear", "Vanish" } }
    dlg:number { id = "n", label = "Frames per transition", text = tostring(prefs.n or 8), decimals = 0 }
    dlg:combobox { id = "bayer", label = "Dither matrix", option = prefs.bayer or "8x8", options = { "4x4", "8x8" } }
    dlg:combobox { id = "dir", label = "Wipe direction", option = prefs.dir or "Top to bottom",
                   options = { "Top to bottom", "Bottom to top", "Left to right", "Right to left" } }
    dlg:check { id = "edge", label = "Wipe / materialise", text = "1-px edge in the sprite's lightest colour", selected = prefs.edge == true }
    dlg:number { id = "seed", label = "Scatter seed", text = tostring(prefs.seed or 1), decimals = 0 }
    dlg:check { id = "ghost", label = "Trail", text = "Faint dither afterimage of the previous frame", selected = prefs.ghost == true }
    dlg:number { id = "duration", label = "Frame ms", text = tostring(prefs.duration or 70), decimals = 0 }
    dlg:check { id = "all", label = "Layers", text = "All visible layers (default: active layer only)", selected = prefs.all == true }
  end
  dlg:separator()
  dlg:button { id = "ok", text = "Generate", focus = true }
  dlg:button { id = "cancel", text = "Cancel" }
  if LITE then
    dlg:separator()
    dlg:label { text = "Full version: wipes, scatter reveals, teleport materialise, edge colour, trails." }
  end
  dlg:show()
  local d = dlg.data
  if not d.ok then return end
  local plan, o, all_layers, duration
  if LITE then
    plan = { { mode = "appear" }, { mode = "vanish" } }
    o = { effect = "dither", n = 6, bayer = 4, dir = "tb", edge = false, seed = 1, ghost = false }
    all_layers, duration = false, 70
  else
    for _, k in ipairs { "effect", "mode", "n", "bayer", "dir", "edge", "seed", "ghost", "duration", "all" } do prefs[k] = d[k] end
    plan = {}
    if d.mode ~= "Vanish" then plan[#plan + 1] = { mode = "appear" } end
    if d.mode ~= "Appear" then plan[#plan + 1] = { mode = "vanish" } end
    o = { effect = EFFECT_OF[d.effect] or "dither", n = math.max(2, math.min(24, math.floor(tonumber(d.n) or 8))),
          bayer = (d.bayer == "4x4") and 4 or 8, dir = DIRS[d.dir] or "tb", edge = d.edge,
          seed = math.floor(tonumber(d.seed) or 1), ghost = d.ghost }
    all_layers, duration = d.all, math.max(20, tonumber(d.duration) or 70)
  end
  local fn = app.frame and app.frame.frameNumber or 1
  local made, msg = generate(spr, layer, fn, plan, o, all_layers, duration)
  if not made then app.alert { title = title, text = msg } end
  app.refresh()
end

function init(plugin)
  local id = LITE and "AppearVanishFXLite" or "AppearVanishFX"
  local title = LITE and "Appear & Vanish FX (Lite)..." or "Appear & Vanish FX..."
  plugin:newCommand { id = id, title = title, group = "cel_popup_properties", onclick = function() show_dialog(plugin) end }
  plugin:newCommand { id = id .. "Edit", title = title, group = "edit_fx", onclick = function() show_dialog(plugin) end }
end

function exit(plugin) end

return { load_core = load_core, generate = generate }
