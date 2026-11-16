-- Offline regression checks. Run from the repository root: lua5.4 dev/garage_defaults_test.lua
-- The production files run in an isolated environment; only native/database boundaries are stubs.
local checks = 0
local function check(value, message)
    assert(value, message)
    checks = checks + 1
end
local function noop() end
local vectorMeta = {}
local function vector(x, y, z, w)
    return setmetatable({ x = x, y = y, z = z, w = w }, vectorMeta)
end
vectorMeta.__sub = function(a, b) return vector(a.x - b.x, a.y - b.y, a.z - b.z) end
vectorMeta.__len = function(v) return math.sqrt(v.x^2 + v.y^2 + v.z^2) end
local function environment()
    return setmetatable({ vector3 = vector, vector4 = vector, print = noop }, { __index = _G })
end
local function run(path, env) assert(loadfile(path, 't', env))() end

-- Real garage records, writes, spot seeding and default reconciliation against an in-memory DB.
local env = environment()
local writes, nextId, failWrite = 0, 0, false
local function write()
    if failWrite then error('simulated database failure') end
    writes = writes + 1
    nextId = nextId + 1
    return nextId
end
env.Config = {}
env.MySQL = { query = { await = write }, insert = { await = write }, update = { await = write } }
env.TriggerClientEvent = noop
env.GetCurrentResourceName = function() return 'whip_core' end
env.GetResourceState = function() return 'started' end
env.exports = noop
env.AddEventHandler = noop
env.Registry = { onRelease = noop }
env.Sanitize = { key = function(s) return s end }
env.WhipEmit = noop
env.WithTableCollation = function(s) return s end
run('server/garages.lua', env)
run('server/garage_spots.lua', env)
run('server/default_garages.lua', env)
local garages, spots = env.Garages, env.GarageSpots
env.SetupDefaultGarages()
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
check(count(garages.getAll()) == 16, 'first startup must create 16 default garages')
check(#spots.all() == 16, 'each default must have exactly one bay')
local before = writes
env.SetupDefaultGarages()
check(writes == before, 'unchanged restart must perform no writes')

local retained = spots.all()[1]
local retainedId, garageKey = retained.spotId, retained.garageKey
local originalX = retained.x
assert(spots.create(garageKey, retained.x + 10, retained.y, retained.z, retained.heading))
env.SetupDefaultGarages()
check(#spots.all() == 16 and spots.get(retainedId) ~= nil, 'remove surplus bays and preserve the nearest bay ID')
assert(spots.update(retainedId, originalX + 1, retained.y, retained.z, retained.heading + 2))
env.SetupDefaultGarages()
check(spots.get(retainedId).x == originalX, 'restore a moved managed bay')
assert(spots.delete(retainedId))
env.SetupDefaultGarages()
check(#spots.all() == 16, 'restore a missing managed bay')

local legacy = garages.get('whip_motelgarage')
legacy.resource = 'whip_garages'
env.SetupDefaultGarages()
check(legacy.resource == 'whip_core', 'adopt the earlier satellite garage')
legacy.resource = 'whip_garages'
failWrite = true
env.SetupDefaultGarages()
check(legacy.resource == 'whip_garages', 'failed adoption must retain the old in-memory owner')
failWrite = false
env.SetupDefaultGarages()

local casino = garages.get('whip_casinogarage')
garages._records.whip_casinogarage = nil
spots.deleteForGarage('whip_casinogarage')
local custom = assert(garages.create({ key = 'custom_casino', name = 'Custom',
    x = casino.x, y = casino.y, z = casino.z,
    spawnX = casino.spawnX, spawnY = casino.spawnY, spawnZ = casino.spawnZ }))
local customCount = #spots.all()
env.SetupDefaultGarages()
check(garages.get('whip_casinogarage') == nil, 'skip a default next to an existing public garage')
check(#spots.all() == customCount and garages.get('custom_casino').garageId == custom.garageId,
    'preserve custom garages and bays')

-- An existing default key owned by another resource must remain that resource's responsibility.
local motel = garages.get('whip_motelgarage')
motel.resource = 'another_resource'
spots.deleteForGarage(motel.key)
env.SetupDefaultGarages()
local motelBays = 0
for _, s in ipairs(spots.all()) do if s.garageKey == motel.key then motelBays = motelBays + 1 end end
check(motelBays == 0 and motel.resource == 'another_resource', 'do not reconcile another resource\'s garage')

print(('OK — %d default garage regression checks'):format(checks))
