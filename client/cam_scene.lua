-- ============================================
-- Camera scenes — playing what a sequence puts in front of its camera
-- ============================================
--
-- A sequence's scene (shared/cam_scene.lua) played on this game: its actors, vehicles and props spawned (local:
-- nobody else sees them), its lights drawn, its focus on the camera, its time and weather on a weather layer, its
-- effects fired, all at the time the camera is at. client/camera.lua plays one with its sequence; the Camera Creator
-- (tools/camera.lua) keeps one up while it edits, at its playhead.
--
--   local sr = CamScene.start(scene, subjects)  -- WAITS: models load. `subjects` (a table) gains every actor's and
--                                               -- vehicle's id; an id already in it is the caller's and not spawned
--   sr:seek(t)                                  -- everything where it is at t (scrubbing: no explosions go off)
--   sr:advance(from, to)                        -- the keys after `from`, up to and at `to`, fire (playing)
--   sr:frame(t, dt, cam)                        -- each frame: lights, focus (on `cam`, a scripted camera)
--   sr:stop()                                   -- everything gone, the world given back
--
-- One scene at a time: starting one stops the last (a camera replaced by another has its scene go with it).
-- Ported from whip_cine (an unofficial WHIP fork of atiysu's aty_cinematic, MIT).

local Scene = CamScene
local LOAD_MS = 5000
local LAYER = 'cameraScene'
local LAYER_PRIORITY = 900        -- over the server's weather and a zone's
local MAX_SHADOWED = 8            -- lights casting shadows at once (the game's budget is small)
local SHADOW_ID = 0x5C40

local current = nil               -- the scene up now

local function warn(fmt, ...) print(('^3[whip_core:camera] scene: ' .. fmt .. '^7'):format(...)) end

local function model(m)
    local hash, why = LoadModel(m, LOAD_MS)
    if not hash then warn('model %s did not load (%s)', tostring(m), tostring(why)) end
    return hash
end

-- ============================================
-- Actors
-- ============================================

local function removeProps(a)
    for _, o in ipairs(a.props) do if DoesEntityExist(o) then DeleteEntity(o) end end
    a.props = {}
end

local function attachProp(a, p)
    local hash = model(p.model)
    if not hash then return end
    local c = GetEntityCoords(a.ped)
    local o = CreateObject(hash, c.x, c.y, c.z + 0.2, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    AttachEntityToEntity(o, a.ped, GetPedBoneIndex(a.ped, p.bone), p.off[1], p.off[2], p.off[3],
        p.rot[1], p.rot[2], p.rot[3], true, true, false, true, 1, true)
    a.props[#a.props + 1] = o
end

--- An emote (shared/emote_list.lua, by its /e name) on an actor: its clip or scenario, and its props in hand.
local emoteByCmd = nil
local function playEmote(a, cmd, instant)
    if not emoteByCmd then
        emoteByCmd = {}
        for _, e in ipairs(EmoteList.emotes) do emoteByCmd[e.cmd] = e end
    end
    local def = emoteByCmd[cmd]
    if not def then warn('there is no emote %s', tostring(cmd)) return end
    removeProps(a)
    if def.scenario then
        TaskStartScenarioInPlace(a.ped, def.scenario, 0, not instant)
    elseif def.dict then
        if not LoadAnimDict(def.dict, LOAD_MS) then warn('emote %s did not load', cmd) return end
        local flag = (def.loop and 1 or 0) + (def.freeze and 2 or 0) + (def.move and 48 or 0)
        TaskPlayAnim(a.ped, def.dict, def.anim, instant and 1000.0 or 8.0, -8.0, -1, flag, 0.0, false, false, false)
    end
    for _, p in ipairs(def.props or {}) do
        attachProp(a, { model = p.model, bone = p.bone or 57005,
            off = { (p.offset or {})[1] or 0.0, (p.offset or {})[2] or 0.0, (p.offset or {})[3] or 0.0 },
            rot = { (p.rot or {})[1] or 0.0, (p.rot or {})[2] or 0.0, (p.rot or {})[3] or 0.0 } })
    end
end

--- One key on an actor. `instant` (seeking): no blend, a walk jumps to where it ends, no ragdoll.
local function actorKey(a, k, instant)
    local ped = a.ped
    if not DoesEntityExist(ped) then return end
    if k.clear then ClearPedTasksImmediately(ped); removeProps(a) end
    if k.hide ~= nil then SetEntityVisible(ped, not k.hide, false) end
    if k.anim then
        if LoadAnimDict(k.anim.dict, LOAD_MS) then
            TaskPlayAnim(ped, k.anim.dict, k.anim.name, instant and 1000.0 or k.anim.speed, -8.0, -1, k.anim.flag, 0.0, false, false, false)
        else
            warn('animation dictionary %s did not load', k.anim.dict)
        end
    end
    if k.scenario then TaskStartScenarioInPlace(ped, k.scenario, 0, not instant) end
    if k.emote then playEmote(a, k.emote, instant) end
    if k.walk then
        if instant then
            SetEntityCoords(ped, k.walk[1], k.walk[2], k.walk[3] - 1.0, false, false, false, false)
        else
            TaskGoStraightToCoord(ped, k.walk[1], k.walk[2], k.walk[3], k.walk.speed, -1, GetEntityHeading(ped), 0.5)
        end
    end
    if k.prop then attachProp(a, k.prop) end
    if k.face then SetFacialIdleAnimOverride(ped, k.face, 0) end
    if k.ragdoll and not instant then SetPedToRagdoll(ped, k.ragdoll, k.ragdoll, 0, false, false, false) end
end

local function actorHome(a)
    local s = a.def.spawn
    SetEntityCoordsNoOffset(a.ped, s[1], s[2], s[3] - 1.0, false, false, false)
    SetEntityHeading(a.ped, s[4])
    ClearPedTasksImmediately(a.ped)
    ClearFacialIdleAnimOverride(a.ped)
    SetEntityVisible(a.ped, true, false)
    removeProps(a)
end

local function spawnActor(def)
    local hash = model(def.model)
    if not hash then return nil end
    local s = def.spawn
    local ped = CreatePed(4, hash, s[1], s[2], s[3] - 1.0, s[4], false, false)
    SetModelAsNoLongerNeeded(hash)
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    SetPedDefaultComponentVariation(ped)
    if def.invincible then SetEntityInvincible(ped, true) end
    if def.outfit then
        for comp, v in pairs(def.outfit) do
            local c = tonumber(comp)
            if c and type(v) == 'table' then SetPedComponentVariation(ped, c, tonumber(v[1]) or 0, tonumber(v[2]) or 0, 0) end
        end
    end
    return { ped = ped, def = def, props = {} }
end

-- ============================================
-- Vehicles
-- ============================================

local function vehicleKey(c, k, instant)
    local veh = c.veh
    if not DoesEntityExist(veh) then return end
    if k.hide ~= nil then SetEntityVisible(veh, not k.hide, false) end
    if k.engine ~= nil then SetVehicleEngineOn(veh, k.engine, true, true) end
    if k.lights ~= nil then SetVehicleLights(veh, k.lights and 3 or 4) end
    if k.siren ~= nil then SetVehicleSiren(veh, k.siren) end
    if k.horn and not instant then StartVehicleHorn(veh, k.horn, GetHashKey('HELDDOWN'), false) end
    if k.door then
        if k.door[2] then SetVehicleDoorOpen(veh, k.door[1], false, instant) else SetVehicleDoorShut(veh, k.door[1], instant) end
    end
    if k.drive then
        if instant then
            SetEntityCoords(veh, k.drive[1], k.drive[2], k.drive[3], false, false, false, false)
            SetVehicleOnGroundProperly(veh)
        elseif c.driver and DoesEntityExist(c.driver) then
            SetVehicleEngineOn(veh, true, true, false)
            TaskVehicleDriveToCoordLongrange(c.driver, veh, k.drive[1], k.drive[2], k.drive[3], k.drive.speed, k.drive.style, 5.0)
        end
    end
end

local function vehicleHome(c)
    local s = c.def.spawn
    if c.driver and DoesEntityExist(c.driver) then ClearPedTasks(c.driver) end
    SetEntityVelocity(c.veh, 0.0, 0.0, 0.0)
    SetEntityCoords(c.veh, s[1], s[2], s[3], false, false, false, false)
    SetEntityHeading(c.veh, s[4])
    SetVehicleOnGroundProperly(c.veh)
    SetVehicleSiren(c.veh, false)
    SetEntityVisible(c.veh, true, false)
    for door = 0, 7 do SetVehicleDoorShut(c.veh, door, true) end
end

local function spawnVehicle(def)
    local hash = model(def.model)
    if not hash then return nil end
    local s = def.spawn
    local veh = CreateVehicle(hash, s[1], s[2], s[3], s[4], false, false)
    SetModelAsNoLongerNeeded(hash)
    SetEntityAsMissionEntity(veh, true, true)
    SetVehicleOnGroundProperly(veh)
    SetVehicleDirtLevel(veh, 0.0)
    SetVehicleDoorsLocked(veh, 2)
    if def.props then pcall(SetVehicleProperties, veh, def.props) end
    local driver
    if def.driver then
        local dh = model(def.driver)
        if dh then
            driver = CreatePedInsideVehicle(veh, 4, dh, -1, false, false)
            SetModelAsNoLongerNeeded(dh)
            SetBlockingOfNonTemporaryEvents(driver, true)
            SetEntityInvincible(driver, true)
            SetPedKeepTask(driver, true)
        end
    end
    return { veh = veh, driver = driver, def = def }
end

-- ============================================
-- Props (moves glide between keys)
-- ============================================

local function propPose(def, t)
    local pos, rot, prevT = def.pos, def.rot, 0
    for _, k in ipairs(def.keys) do
        if k.move or k.turn then
            if k.t <= t then
                pos, rot, prevT = k.move or pos, k.turn or rot, k.t
            else
                local span = k.t - prevT
                local u = span > 0 and Scene.smooth((t - prevT) / span) or 1.0
                local p2, r2 = k.move or pos, k.turn or rot
                return { Scene.lerp(pos[1], p2[1], u), Scene.lerp(pos[2], p2[2], u), Scene.lerp(pos[3], p2[3], u) },
                       { Scene.lerp(rot[1], r2[1], u), Scene.lerp(rot[2], r2[2], u), Scene.lerp(rot[3], r2[3], u) }
            end
        end
    end
    return pos, rot
end

local function propShown(def, t)
    local vis = true
    for _, k in ipairs(def.keys) do
        if k.t > t then break end
        if k.hide ~= nil then vis = not k.hide end
    end
    return vis
end

local function placeProp(o, t)
    local p, r = propPose(o.def, t)
    SetEntityCoordsNoOffset(o.obj, p[1], p[2], p[3], false, false, false)
    SetEntityRotation(o.obj, r[1], r[2], r[3], 2, true)
    SetEntityVisible(o.obj, propShown(o.def, t), false)
end

local function spawnProp(def)
    local hash = model(def.model)
    if not hash then return nil end
    local obj = CreateObjectNoOffset(hash, def.pos[1], def.pos[2], def.pos[3], false, false, false)
    SetModelAsNoLongerNeeded(hash)
    SetEntityRotation(obj, def.rot[1], def.rot[2], def.rot[3], 2, true)
    if def.frozen then FreezeEntityPosition(obj, true) end
    local moves = false
    for _, k in ipairs(def.keys) do if k.move or k.turn then moves = true break end end
    return { obj = obj, def = def, moves = moves }
end

-- ============================================
-- Lights (drawn every frame)
-- ============================================

--- A light's `field` at t: eased from the key before to the key after that sets it.
local function lightValue(l, t, field)
    local prev, prevT, nxt = l[field], 0, nil
    for _, k in ipairs(l.keys) do
        if k[field] ~= nil then
            if k.t <= t then prev, prevT = k[field], k.t else nxt = k break end
        end
    end
    if not nxt then return prev end
    local span = nxt.t - prevT
    local u = span > 0 and Scene.smooth((t - prevT) / span) or 1.0
    local b = nxt[field]
    if type(prev) == 'table' then
        return { Scene.lerp(prev[1], b[1], u), Scene.lerp(prev[2], b[2], u), Scene.lerp(prev[3], b[3], u) }
    end
    return Scene.lerp(prev, b, u)
end

local function lightState(l, t)
    local on, flicker = l.on, 0.0
    for _, k in ipairs(l.keys) do
        if k.t > t then break end
        if k.on ~= nil then on = k.on end
        if k.flicker ~= nil then flicker = k.flicker end
    end
    return on, flicker
end

local function drawLights(sr, t)
    local shadowed, now = 0, GetGameTimer()
    for i, l in ipairs(sr.scene.lights) do
        local on, flicker = lightState(l, t)
        if on then
            local intensity = lightValue(l, t, 'intensity')
            if flicker > 0 then
                -- two waves out of step and a little noise: a lamp that buzzes, not a strobe
                local w = math.sin(now * 0.031 + i) * 0.5 + math.sin(now * 0.0137 + i * 3) * 0.5
                intensity = math.max(0.0, intensity * (1.0 - flicker * (0.5 + 0.5 * (w + (math.random() - 0.5) * 0.6))))
            end
            local range, c = lightValue(l, t, 'range'), lightValue(l, t, 'color')
            local x, y, z = l.pos[1], l.pos[2], l.pos[3]
            local dx, dy, dz = l.dir[1], l.dir[2], l.dir[3]
            local ent = l.follow and sr.subjects[l.follow]
            if type(ent) == 'number' and DoesEntityExist(ent) then
                local p = GetOffsetFromEntityInWorldCoords(ent, x, y, z)
                local f = GetOffsetFromEntityInWorldCoords(ent, x + dx, y + dy, z + dz)
                x, y, z, dx, dy, dz = p.x, p.y, p.z, f.x - p.x, f.y - p.y, f.z - p.z
            end
            local r, g, b = math.floor(c[1]), math.floor(c[2]), math.floor(c[3])
            local shadow = l.shadow and shadowed < MAX_SHADOWED
            if shadow then shadowed = shadowed + 1 end
            if l.kind == 'spot' then
                if shadow then
                    DrawSpotLightWithShadow(x + 0.0, y + 0.0, z + 0.0, dx + 0.0, dy + 0.0, dz + 0.0, r, g, b,
                        range + 0.0, intensity + 0.0, l.inner + 0.0, l.outer + 0.0, l.falloff + 0.0, SHADOW_ID + i)
                else
                    DrawSpotLight(x + 0.0, y + 0.0, z + 0.0, dx + 0.0, dy + 0.0, dz + 0.0, r, g, b,
                        range + 0.0, intensity + 0.0, l.inner + 0.0, l.outer + 0.0, l.falloff + 0.0)
                end
            elseif shadow then
                DrawLightWithRangeAndShadow(x + 0.0, y + 0.0, z + 0.0, r, g, b, range + 0.0, intensity + 0.0, l.falloff + 0.0)
            else
                DrawLightWithRange(x + 0.0, y + 0.0, z + 0.0, r, g, b, range + 0.0, intensity + 0.0)
            end
        end
    end
end

-- ============================================
-- Focus (depth of field on the camera)
-- ============================================

local function focusPoint(sr, f)
    if type(f) == 'string' then
        local e = sr.subjects[f]
        if type(e) == 'number' and DoesEntityExist(e) then return GetEntityCoords(e) end
        if type(e) == 'table' then return vector3(e.x or e[1], e.y or e[2], e.z or e[3]) end
        return nil
    elseif type(f) == 'table' then
        return vector3(f[1], f[2], f[3])
    end
end

local function focusOff(sr)
    if sr.dofOn and sr.dofCam and DoesCamExist(sr.dofCam) then SetCamUseShallowDofMode(sr.dofCam, false) end
    sr.dofOn = false
end

local function focus(sr, t, dt, cam)
    local keys = sr.scene.dof.keys
    if cam ~= sr.dofCam then focusOff(sr); sr.dofCam = cam end
    if #keys == 0 or not cam or not DoesCamExist(cam) then return focusOff(sr) end
    local a, b, u = Scene.between(keys, t)
    if not a or a.t > t or a.off then return focusOff(sr) end
    if b.off then b = a end
    u = Scene.smooth(u)
    local near, far = Scene.lerp(a.near, b.near, u), Scene.lerp(a.far, b.far, u)
    local str = Scene.lerp(a.strength, b.strength, u)
    -- A focus pull: the sharp band centred on the subject's distance, from a's subject to b's.
    local pa, pb = focusPoint(sr, a.focus), focusPoint(sr, b.focus)
    if pa or pb then
        local c = GetCamCoord(cam)
        local da = pa and #(pa - c) or nil
        local db = pb and #(pb - c) or da
        local want = Scene.lerp(da or db, db, u)
        sr.focusDist = sr.focusDist and (sr.focusDist + (want - sr.focusDist) * math.min(1.0, dt * 8.0)) or want
        local half = math.max((far - near) * 0.5, 0.05)
        near, far = math.max(sr.focusDist - half, 0.0), sr.focusDist + half
    end
    SetCamUseShallowDofMode(cam, true)
    SetUseHiDof()   -- every frame
    SetCamNearDof(cam, near + 0.0)
    SetCamFarDof(cam, far + 0.0)
    SetCamDofStrength(cam, str + 0.0)
    sr.dofOn = true
end

-- ============================================
-- Time, weather, wind, rain, blackout, filter
-- ============================================

local function lastOf(keys, t, field)
    local v, at
    for _, k in ipairs(keys) do
        if k.t > t then break end
        if k[field] ~= nil then v, at = k[field], k end
    end
    return v, at
end

--- Minutes after midnight at t, eased to the next key with a time (the short way round midnight).
local function minutesAt(keys, t)
    local prev, nxt
    for _, k in ipairs(keys) do
        if k.hour ~= nil then
            if k.t <= t then prev = k else nxt = k break end
        end
    end
    if not prev then return nil end
    local m1 = prev.hour * 60 + prev.minute
    if not nxt then return m1 end
    local d = (nxt.hour * 60 + nxt.minute) - m1
    if d > 720 then d = d - 1440 elseif d < -720 then d = d + 1440 end
    return (m1 + d * Scene.smooth((t - prev.t) / math.max(1, nxt.t - prev.t))) % 1440
end

local function world(sr, t, force)
    local keys = sr.scene.env.keys
    if #keys == 0 then return end
    local weather = lastOf(keys, t, 'weather')
    local mins = minutesAt(keys, t)
    local hour, minute = mins and math.floor(mins / 60) or nil, mins and math.floor(mins % 60) or nil
    local sent = sr.envSent
    if force or weather ~= sent.weather or hour ~= sent.hour or minute ~= sent.minute then
        sr.envSent = { weather = weather, hour = hour, minute = minute }
        WeatherLayer.set(LAYER, { priority = LAYER_PRIORITY, weather = weather, hour = hour, minute = minute, frozen = true })
        sr.layer = true
    end
    local wind = lastOf(keys, t, 'wind')
    if wind then SetWind(wind / 12.0); SetWindSpeed(wind + 0.0) end
    local rain = lastOf(keys, t, 'rain')
    if rain then SetRainLevel(rain + 0.0) end
    local blackout = lastOf(keys, t, 'blackout')
    if blackout ~= nil and blackout ~= sr.blackout then
        sr.blackout = blackout
        SetArtificialLightsState(blackout)
        SetArtificialLightsStateAffectsVehicles(false)
    end
    local filter, fk = lastOf(keys, t, 'filter')
    if (filter or nil) ~= sr.filter or force then
        if filter then SetTimecycleModifier(filter); SetTimecycleModifierStrength(fk.filterStrength + 0.0)
        elseif sr.filter then ClearTimecycleModifier() end
        sr.filter = filter or nil
    end
end

-- ============================================
-- Effects (fire when played past, never when scrubbed)
-- ============================================

local function fireFx(sr, k)
    local p = k.particle
    if p then
        if LoadPtfxAsset(p.asset, LOAD_MS) then
            UseParticleFxAsset(p.asset)
            local ent = p.on and sr.subjects[p.on]
            ent = type(ent) == 'number' and DoesEntityExist(ent) and ent or nil
            local x, y, z, rx, ry, rz, sc = p.pos[1], p.pos[2], p.pos[3], p.rot[1], p.rot[2], p.rot[3], p.scale + 0.0
            if p.dur > 0 then
                local h = ent and StartParticleFxLoopedOnEntity(p.name, ent, x, y, z, rx, ry, rz, sc, false, false, false)
                    or StartParticleFxLoopedAtCoord(p.name, x, y, z, rx, ry, rz, sc, false, false, false, false)
                sr.live[#sr.live + 1] = { kind = 'ptfx', handle = h, untilT = k.t + p.dur }
            elseif ent then
                StartParticleFxNonLoopedOnEntity(p.name, ent, x, y, z, rx, ry, rz, sc, false, false, false)
            else
                StartParticleFxNonLoopedAtCoord(p.name, x, y, z, rx, ry, rz, sc, false, false, false)
            end
        else
            warn('particle asset %s did not load', p.asset)
        end
    end
    local e = k.explosion
    if e then AddExplosion(e.pos[1], e.pos[2], e.pos[3], e.kind, e.scale + 0.0, not e.silent, false, 0.5) end
    if k.screen then
        AnimpostfxPlay(k.screen.name, 0, k.screen.dur == 0)
        if k.screen.dur > 0 then sr.live[#sr.live + 1] = { kind = 'screen', name = k.screen.name, untilT = k.t + k.screen.dur } end
    end
    local s = k.sound
    if s then
        if s.pos then PlaySoundFromCoord(-1, s.name, s.pos[1], s.pos[2], s.pos[3], s.set or 0, false, 0, false)
        else PlaySoundFrontend(-1, s.name, s.set or 0, true) end
    end
    if k.shake then ShakeGameplayCam(k.shake.name, k.shake.amount + 0.0) end
end

local function stopLive(e)
    if e.kind == 'ptfx' then StopParticleFxLooped(e.handle, false)
    elseif e.kind == 'screen' then AnimpostfxStop(e.name) end
end

local function stopAllFx(sr)
    for _, e in ipairs(sr.live) do stopLive(e) end
    sr.live = {}
end

-- ============================================
-- A scene run
-- ============================================

local Run = {}
Run.__index = Run

--- Everything where it is at t, without anything going off.
function Run:seek(t)
    if self.stopped then return end
    for _, a in pairs(self.actors) do
        if DoesEntityExist(a.ped) then
            actorHome(a)
            for _, k in ipairs(a.def.keys) do
                if k.t >= t then break end
                actorKey(a, k, true)
            end
        end
    end
    for _, c in pairs(self.vehicles) do
        if DoesEntityExist(c.veh) then
            vehicleHome(c)
            for _, k in ipairs(c.def.keys) do
                if k.t >= t then break end
                vehicleKey(c, k, true)
            end
        end
    end
    for _, o in pairs(self.props) do if DoesEntityExist(o.obj) then placeProp(o, t) end end
    stopAllFx(self)
    self.focusDist = nil
    world(self, t, true)
    self.t = t
end

--- Played on from `from` to `to`: the keys after `from`, up to and at `to`, fire.
function Run:advance(from, to)
    if self.stopped or to < from then return end
    for _, a in pairs(self.actors) do
        for _, k in ipairs(a.def.keys) do
            if k.t > to then break end
            if k.t > from or (from == 0 and k.t == 0 and not self.firedZero) then actorKey(a, k, false) end
        end
    end
    for _, c in pairs(self.vehicles) do
        for _, k in ipairs(c.def.keys) do
            if k.t > to then break end
            if k.t > from or (from == 0 and k.t == 0 and not self.firedZero) then vehicleKey(c, k, false) end
        end
    end
    for _, o in pairs(self.props) do
        if DoesEntityExist(o.obj) then
            if o.moves then placeProp(o, to)
            else
                for _, k in ipairs(o.def.keys) do
                    if k.t > to then break end
                    if k.t > from and k.hide ~= nil then SetEntityVisible(o.obj, not k.hide, false) end
                end
            end
        end
    end
    for _, k in ipairs(self.scene.fx) do
        if k.t > to then break end
        if k.t > from or (from == 0 and k.t == 0 and not self.firedZero) then fireFx(self, k) end
    end
    for i = #self.live, 1, -1 do
        if to >= self.live[i].untilT then stopLive(self.live[i]); table.remove(self.live, i) end
    end
    if from == 0 then self.firedZero = true end
    world(self, to, false)
    self.t = to
end

--- Each frame: the lights, and the focus on `cam` (a scripted camera; nil leaves the focus off).
function Run:frame(t, dt, cam)
    if self.stopped then return end
    drawLights(self, t)
    focus(self, t, dt or 0.016, cam)
end

--- Everything gone, and the world given back.
function Run:stop()
    if self.stopped then return end
    self.stopped = true
    for id, a in pairs(self.actors) do
        removeProps(a)
        if DoesEntityExist(a.ped) then DeleteEntity(a.ped) end
        if self.subjects[id] == a.ped then self.subjects[id] = nil end
    end
    for id, c in pairs(self.vehicles) do
        if c.driver and DoesEntityExist(c.driver) then DeleteEntity(c.driver) end
        if DoesEntityExist(c.veh) then DeleteEntity(c.veh) end
        if self.subjects[id] == c.veh then self.subjects[id] = nil end
    end
    for id, o in pairs(self.props) do
        if DoesEntityExist(o.obj) then DeleteEntity(o.obj) end
        if self.subjects[id] == o.obj then self.subjects[id] = nil end
    end
    stopAllFx(self)
    focusOff(self)
    if self.layer then WeatherLayer.set(LAYER, nil) end
    if self.filter then ClearTimecycleModifier() end
    if self.blackout then SetArtificialLightsState(false) end
    SetRainLevel(-1.0)
    if current == self then current = nil end
end

--- The entity standing for an actor, vehicle or prop id (nil when it is not up).
function Run:entity(id)
    local a, c, o = self.actors[id], self.vehicles[id], self.props[id]
    return (a and a.ped) or (c and c.veh) or (o and o.obj) or nil
end

--- Start a scene (a clean one: CamSequence.clean's out.scene). WAITS while models load. `subjects` is the run's
--- table of names: an actor's or vehicle's id already in it is the caller's (their own car for 'car1') and that
--- one is not spawned; the rest are added. nil when there is no scene.
---@param scene table|nil
---@param subjects table|nil
---@return table|nil run
function CamScene.start(scene, subjects)
    if current then current:stop() end
    if not scene then return nil end
    local sr = setmetatable({ scene = scene, subjects = subjects or {}, actors = {}, vehicles = {}, props = {},
        live = {}, envSent = {}, t = 0.0 }, Run)
    current = sr
    for _, def in ipairs(scene.actors) do
        if sr.stopped then return nil end
        if sr.subjects[def.id] == nil then
            local a = spawnActor(def)
            if a then sr.actors[def.id] = a; sr.subjects[def.id] = a.ped end
        end
    end
    for _, def in ipairs(scene.vehicles) do
        if sr.stopped then return nil end
        if sr.subjects[def.id] == nil then
            local c = spawnVehicle(def)
            if c then sr.vehicles[def.id] = c; sr.subjects[def.id] = c.veh end
        end
    end
    for _, def in ipairs(scene.props) do
        if sr.stopped then return nil end
        local o = spawnProp(def)
        if o then
            sr.props[def.id] = o
            if sr.subjects[def.id] == nil then sr.subjects[def.id] = o.obj end
        end
    end
    if sr.stopped then return nil end
    return sr
end

--- The scene up now (or nil).
function CamScene.current() return current end

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and current then current:stop() end
end)
