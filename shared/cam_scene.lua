-- ============================================
-- Camera scenes — what a Camera Creator sequence puts in front of its camera
-- ============================================
--
-- A sequence (shared/cam_sequence.lua) may carry a `scene`: actors, vehicles, props, lights, focus, time and
-- weather, and effects, each keyed along the same timeline as the camera. The scene is spawned for whoever plays
-- the sequence (on their game only), its actors and vehicles are the camera's subjects by their ids (an orbit of
-- 'hero', a chase of 'car1'), and it is gone when the camera stops. client/cam_scene.lua plays it; the Camera
-- Creator (tools/camera.lua) edits it. Ported from whip_cine (an unofficial WHIP fork of atiysu's aty_cinematic), under
-- aty_cinematic's licence:
--
-- MIT License
--
-- Copyright (c) 2026 atiysu
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
--
--   scene = {
--     actors   = { { id = 'hero', model = 'a_m_y_business_01', spawn = { x, y, z, h },
--                    keys = { { t, emote = 'wave' (an /e name: shared/emote_list.lua) }, { t, anim = { dict, name, flag } }, { t, walk = { x, y, z, speed } },
--                             { t, scenario = 'WORLD_HUMAN_SMOKING' }, { t, prop = { model, bone, off, rot } },
--                             { t, face = 'mood_angry_1' }, { t, ragdoll = 2000 }, { t, hide = true }, { t, clear = true } } } },
--     vehicles = { { id = 'car1', model = 'elegy', spawn = { x, y, z, h }, driver = 'a_m_y_stbla_02' | nil,
--                    keys = { { t, drive = { x, y, z, speed, style } }, { t, lights = true }, { t, siren = true },
--                             { t, horn = 500 }, { t, door = { 0, true } }, { t, engine = true }, { t, hide = true } } } },
--     props    = { { id = 'box', model = 'prop_box_wood02a', pos = { x, y, z }, rot = { x, y, z },
--                    keys = { { t, hide = true }, { t, move = { x, y, z } }, { t, turn = { x, y, z } } } } },
--     lights   = { { id = 'key', kind = 'point'|'spot', pos = { x, y, z }, dir = { x, y, z }, color = { r, g, b },
--                    range = 8, intensity = 4, inner = 20, outer = 40, shadow = false, follow = 'hero' | nil,
--                    keys = { { t, intensity = 6, color = {...}, range = 10, flicker = 0.3, on = false } } } },
--     dof      = { keys = { { t, near = 0.5, far = 12, strength = 1, focus = 'hero' | { x, y, z } | nil, off = true? } } },
--     env      = { keys = { { t, hour = 18, minute = 30, weather = 'CLEAR', wind = 0.2, rain = 0, blackout = false } } },
--     fx       = { { t, particle = { asset, name, pos, rot, scale, dur, on } }, { t, explosion = { pos, kind, scale } },
--                  { t, screen = { name, dur } }, { t, sound = { name, set, pos } }, { t, shake = { name, amount } } },
--     markers  = { { t, label } },
--   }
--
-- CamScene.clean copies only known fields, clamps every number and drops anything malformed (a scene from a client
-- is untrusted; the server saves only what this lets through). A key's t is clamped into the sequence's length and
-- each lane's keys are sorted by time. Ids are subject names: letters, digits and _, never player, vehicle or target.

CamScene = {}
local Scene = CamScene

local LIM = {
    Actors = 24, Vehicles = 12, Props = 48, Lights = 16, Fx = 96,
    KeysPerLane = 256,
}
CamScene.LIMITS = LIM
local MAX_COORD = 20000.0

local function isNum(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end

local function num(v, lo, hi, default)
    if not isNum(v) then return default end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- A short name made of letters, digits, _ - . : and spaces.
local function name(v, maxLen, default)
    if type(v) ~= 'string' then return default end
    v = v:gsub('[^%w_%-%.: ]', ''):sub(1, maxLen or 64)
    v = v:match('^%s*(.-)%s*$')
    if v == '' then return default end
    return v
end

--- An identifier inside a scene: lower letters, digits, _ (actor and vehicle ids are camera subject names).
local function ident(v)
    if type(v) ~= 'string' then return nil end
    v = v:lower():gsub('[^%w_]', ''):sub(1, 24)
    if v == '' or v == 'player' or v == 'vehicle' or v == 'target' then return nil end   -- the built-in subject names
    return v
end

local function model(v)
    if isNum(v) then return math.floor(v) end
    return name(v, 48)
end

local function vec3(v, limit)
    if type(v) ~= 'table' then return nil end
    local x, y, z = v.x or v[1], v.y or v[2], v.z or v[3]
    if not (isNum(x) and isNum(y) and isNum(z)) then return nil end
    limit = limit or MAX_COORD
    return { num(x, -limit, limit, 0), num(y, -limit, limit, 0), num(z, -limit, limit, 0) }
end

local function vec4(v)
    if type(v) ~= 'table' then return nil end
    local p = vec3(v)
    if not p then return nil end
    p[4] = num(v.w or v.h or v[4], -360, 360, 0)
    return p
end

local function color(v)
    if type(v) ~= 'table' then return nil end
    return { num(v[1] or v.r, 0, 255, 255), num(v[2] or v.g, 0, 255, 255), num(v[3] or v.b, 0, 255, 255) }
end

local function bool(v) if v == nil then return nil end return v == true end

local function sortKeys(keys)
    table.sort(keys, function(a, b) return a.t < b.t end)
    return keys
end

--- Clean a list of keys with a per-key cleaner. Keys the cleaner refuses are dropped.
local function cleanKeys(list, length, cleaner)
    local out = {}
    if type(list) ~= 'table' then return out end
    for _, k in ipairs(list) do
        if #out >= LIM.KeysPerLane then break end
        if type(k) == 'table' then
            local t = num(k.t, 0, length, nil)
            if t then
                local c = cleaner(k)
                if c then c.t = math.floor(t); out[#out + 1] = c end
            end
        end
    end
    return sortKeys(out)
end

-- Per-lane key cleaners ------------------------------------------------------------------------

local function actorKey(k)
    local o = {}
    if type(k.anim) == 'table' then
        local d, n = name(k.anim.dict or k.anim[1], 96), name(k.anim.name or k.anim[2], 96)
        if d and n then o.anim = { dict = d, name = n, flag = math.floor(num(k.anim.flag or k.anim[3], 0, 1048575, 1)),
            speed = num(k.anim.speed, 0.1, 8, 8.0) } end
    end
    if type(k.walk) == 'table' then
        local p = vec3(k.walk)
        if p then o.walk = { p[1], p[2], p[3], speed = num(k.walk.speed or k.walk[4], 0.1, 3.0, 1.0) } end
    end
    if k.scenario then o.scenario = name(k.scenario, 64) end
    if k.emote then o.emote = name(k.emote, 32) end
    if type(k.prop) == 'table' then
        local m = model(k.prop.model or k.prop[1])
        if m then o.prop = { model = m, bone = math.floor(num(k.prop.bone, 0, 65535, 57005)),
            off = vec3(k.prop.off, 5) or { 0, 0, 0 }, rot = vec3(k.prop.rot, 360) or { 0, 0, 0 } } end
    end
    if k.face then o.face = name(k.face, 48) end
    if k.ragdoll then o.ragdoll = math.floor(num(k.ragdoll, 100, 20000, 2000)) end
    if k.hide ~= nil then o.hide = bool(k.hide) end
    if k.clear then o.clear = true end
    if next(o) == nil then return nil end
    return o
end

local function vehicleKey(k)
    local o = {}
    if type(k.drive) == 'table' then
        local p = vec3(k.drive)
        if p then o.drive = { p[1], p[2], p[3], speed = num(k.drive.speed or k.drive[4], 1, 120, 20),
            style = math.floor(num(k.drive.style, 0, 2147483647, 786603)) } end
    end
    if k.lights ~= nil then o.lights = bool(k.lights) end
    if k.siren ~= nil then o.siren = bool(k.siren) end
    if k.engine ~= nil then o.engine = bool(k.engine) end
    if k.horn then o.horn = math.floor(num(k.horn, 50, 10000, 500)) end
    if type(k.door) == 'table' then
        o.door = { math.floor(num(k.door[1], 0, 7, 0)), k.door[2] == true }
    end
    if k.hide ~= nil then o.hide = bool(k.hide) end
    if next(o) == nil then return nil end
    return o
end

local function propKey(k)
    local o = {}
    if k.hide ~= nil then o.hide = bool(k.hide) end
    if k.move then o.move = vec3(k.move) end
    if k.turn then o.turn = vec3(k.turn, 360) end
    if next(o) == nil then return nil end
    return o
end

local function lightKey(k)
    local o = {}
    if k.intensity then o.intensity = num(k.intensity, 0, 100, 4) end
    if k.range then o.range = num(k.range, 0.1, 100, 8) end
    if k.color then o.color = color(k.color) end
    if k.flicker then o.flicker = num(k.flicker, 0, 1, 0) end
    if k.on ~= nil then o.on = bool(k.on) end
    if next(o) == nil then return nil end
    return o
end

local function dofKey(k)
    local o = { near = num(k.near, 0, 1000, 0.5), far = num(k.far, 0, 2000, 12), strength = num(k.strength, 0, 1, 1) }
    if type(k.focus) == 'string' then o.focus = ident(k.focus)
    elseif type(k.focus) == 'table' then o.focus = vec3(k.focus) end
    if k.off then o.off = true end
    return o
end

local WEATHERS = {
    EXTRASUNNY = true, CLEAR = true, CLOUDS = true, SMOG = true, FOGGY = true, OVERCAST = true, RAIN = true,
    THUNDER = true, CLEARING = true, NEUTRAL = true, SNOW = true, BLIZZARD = true, SNOWLIGHT = true,
    XMAS = true, HALLOWEEN = true,
}
Scene.WEATHERS = WEATHERS

local function envKey(k)
    local o = {}
    if k.hour ~= nil then o.hour = math.floor(num(k.hour, 0, 23, 12)); o.minute = math.floor(num(k.minute, 0, 59, 0)) end
    if type(k.weather) == 'string' and WEATHERS[k.weather:upper()] then o.weather = k.weather:upper() end
    if k.wind then o.wind = num(k.wind, 0, 12, 0) end
    if k.rain then o.rain = num(k.rain, 0, 1, 0) end
    if k.blackout ~= nil then o.blackout = bool(k.blackout) end
    if k.filter ~= nil then o.filter = name(k.filter, 64) or false; o.filterStrength = num(k.filterStrength, 0, 1, 1) end
    if next(o) == nil then return nil end
    return o
end

local function fxKey(k)
    local o = {}
    if type(k.particle) == 'table' then
        local a, n, p = name(k.particle.asset, 64), name(k.particle.name, 64), vec3(k.particle.pos)
        if a and n and p then o.particle = { asset = a, name = n, pos = p, rot = vec3(k.particle.rot, 360) or { 0, 0, 0 },
            scale = num(k.particle.scale, 0.01, 20, 1), dur = math.floor(num(k.particle.dur, 0, 600000, 0)),
            on = ident(k.particle.on) } end
    end
    if type(k.explosion) == 'table' then
        local p = vec3(k.explosion.pos)
        if p then o.explosion = { pos = p, kind = math.floor(num(k.explosion.kind, 0, 82, 2)),
            scale = num(k.explosion.scale, 0.1, 10, 1), silent = k.explosion.silent == true } end
    end
    if type(k.screen) == 'table' then
        local n = name(k.screen.name, 64)
        if n then o.screen = { name = n, dur = math.floor(num(k.screen.dur, 0, 600000, 0)) } end
    end
    if type(k.sound) == 'table' then
        local n = name(k.sound.name, 64)
        if n then o.sound = { name = n, set = name(k.sound.set, 64), pos = vec3(k.sound.pos) } end
    end
    if k.shake then o.shake = { name = name(k.shake.name, 48) or 'SMALL_EXPLOSION_SHAKE', amount = num(k.shake.amount, 0, 5, 0.5) } end
    if next(o) == nil then return nil end
    return o
end

-- Entity lists ---------------------------------------------------------------------------------

local function cleanList(list, max, length, used, build)
    local out = {}
    if type(list) ~= 'table' then return out end
    for _, e in ipairs(list) do
        if #out >= max then break end
        if type(e) == 'table' then
            local id = ident(e.id)
            if id and not used[id] then
                local c = build(e, length)
                if c then used[id] = true; c.id = id; out[#out + 1] = c end
            end
        end
    end
    return out
end

Scene.Name = name
Scene.Ident = ident

--- A safe copy of a sequence's scene for a timeline `length` ms long, or nil when it has nothing in it.
---@param doc table|nil
---@param length number
---@return table|nil
function Scene.clean(doc, length)
    if type(doc) ~= 'table' then return nil end
    length = math.floor(num(length, 0, 30 * 60 * 1000, 0))
    local used = { player = true, vehicle = true, target = true }
    local s = {}

    s.actors = cleanList(doc.actors, LIM.Actors, length, used, function(e)
        local m, sp = model(e.model), vec4(e.spawn)
        if not (m and sp) then return nil end
        return { model = m, spawn = sp, keys = cleanKeys(e.keys, length, actorKey),
            invincible = e.invincible ~= false, outfit = type(e.outfit) == 'table' and e.outfit or nil }
    end)
    s.vehicles = cleanList(doc.vehicles, LIM.Vehicles, length, used, function(e)
        local m, sp = model(e.model), vec4(e.spawn)
        if not (m and sp) then return nil end
        local driver = e.driver ~= nil and model(e.driver) or nil
        return { model = m, spawn = sp, props = type(e.props) == 'table' and e.props or nil, driver = driver,
            keys = cleanKeys(e.keys, length, vehicleKey) }
    end)
    s.props = cleanList(doc.props, LIM.Props, length, used, function(e)
        local m, p = model(e.model), vec3(e.pos)
        if not (m and p) then return nil end
        return { model = m, pos = p, rot = vec3(e.rot, 360) or { 0, 0, 0 }, frozen = e.frozen ~= false,
            keys = cleanKeys(e.keys, length, propKey) }
    end)
    s.lights = cleanList(doc.lights, LIM.Lights, length, used, function(e)
        local p = vec3(e.pos)
        if not p then return nil end
        return { kind = e.kind == 'spot' and 'spot' or 'point', pos = p, dir = vec3(e.dir, 1) or { 0, 0, -1 },
            color = color(e.color) or { 255, 214, 170 }, range = num(e.range, 0.1, 100, 8),
            intensity = num(e.intensity, 0, 100, 4), inner = num(e.inner, 1, 89, 20), outer = num(e.outer, 1, 90, 40),
            falloff = num(e.falloff, 0.1, 50, 4), shadow = e.shadow == true, on = e.on ~= false,
            follow = ident(e.follow), keys = cleanKeys(e.keys, length, lightKey) }
    end)

    s.dof = { keys = cleanKeys(type(doc.dof) == 'table' and doc.dof.keys, length, dofKey) }
    s.env = { keys = cleanKeys(type(doc.env) == 'table' and doc.env.keys, length, envKey) }
    s.fx = cleanKeys(doc.fx, length, fxKey)
    while #s.fx > LIM.Fx do table.remove(s.fx) end
    s.markers = cleanKeys(doc.markers, length, function(k)
        return { label = name(k.label, 32, 'Beat') }
    end)

    if #s.actors + #s.vehicles + #s.props + #s.lights + #s.dof.keys + #s.env.keys + #s.fx + #s.markers == 0 then
        return nil
    end
    return s
end

--- The time of a scene's last key (0 with none).
function Scene.lastKey(s)
    local last = 0
    local function lane(keys) if keys[#keys] and keys[#keys].t > last then last = keys[#keys].t end end
    for _, list in ipairs({ s.actors, s.vehicles, s.props, s.lights }) do
        for _, e in ipairs(list) do lane(e.keys) end
    end
    lane(s.dof.keys); lane(s.env.keys); lane(s.fx); lane(s.markers)
    return last
end

--- Every subject name a scene hands the camera: actor and vehicle ids.
function Scene.subjectIds(s)
    if not s then return {} end
    local out = {}
    for _, a in ipairs(s.actors or {}) do out[#out + 1] = a.id end
    for _, v in ipairs(s.vehicles or {}) do out[#out + 1] = v.id end
    return out
end

--- The last key at or before t in a sorted list (and its index), or nil.
function Scene.keyAt(keys, t)
    local found, idx = nil, nil
    for i = 1, #keys do
        if keys[i].t <= t then found, idx = keys[i], i else break end
    end
    return found, idx
end

--- The keys on either side of t, and how far between them t is (0..1). For eased values.
function Scene.between(keys, t)
    local a, ia = Scene.keyAt(keys, t)
    if not a then return keys[1], keys[1], 0.0 end
    local b = keys[ia + 1]
    if not b then return a, a, 0.0 end
    local span = b.t - a.t
    if span <= 0 then return b, b, 0.0 end
    return a, b, (t - a.t) / span
end

function Scene.smooth(u) return u * u * (3 - 2 * u) end
function Scene.lerp(a, b, u) return a + (b - a) * u end
