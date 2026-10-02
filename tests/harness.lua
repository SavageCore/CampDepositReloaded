-- Stubbed UE4SS harness for CampDepositReloaded. Run with: make test.
--
-- Models what the 2026-10-02 debug log measured:
--   - the RPC's by-value params come back as opaque UScriptStruct userdata
--   - every interaction constructs an interact option ability whose GetOuter() is
--     the player state, and the deposit/door/chest-open classes all differ
--   - camp scoping works (R5BuildingCenterStorageComponent.BuildingGraphIds)
--   - the replay only works with the target data unwrapped
--
-- Stages the mod next to a generated config under build/harness/run, stubs the
-- UE4SS API, loads main.lua and drives it, then asserts the behaviour the
-- reports demanded: deposits fan out, nothing else does, the owner pointer is
-- restored after every single replay, and a renamed option class warns instead of
-- going silently inert.
local SEP = "/"

-- Make passes every switch as 0/1, and in Lua "0" is truthy.
local function flag(name)
    local value = os.getenv(name)
    return value ~= nil and value ~= "" and value ~= "0"
end
local scriptDir = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "") .. "harness.lua"
local repoRoot = scriptDir:gsub("[/\\]tests[/\\]harness%.lua$", "")
if repoRoot == scriptDir then repoRoot = "." end
local HERE = repoRoot .. SEP .. "build" .. SEP .. "harness" .. SEP .. "run"
os.execute("mkdir -p '" .. HERE .. "'")
package.path = HERE .. SEP .. "?.lua;" .. package.path

--------------------------------------------------------------------- UE4SS stub
local hooks, newObjectHooks, delays = {}, {}, {}
local clock = 0

local function obj(fields)
    local store = fields or {}
    return setmetatable({}, {
        __index = function(_, key)
            local v = store[key]
            if v ~= nil then return v end
            if key == "IsValid" then return function() return not store.__dead end end
            return nil
        end,
        __newindex = function(_, key, value) store[key] = value end,
    })
end

local worldCtx = obj({})
local statics = obj({ GetTimeSeconds = function() return clock end })
package.preload["UEHelpers"] = function()
    return {
        GetWorld = function() return worldCtx end,
        GetGameModeBase = function() return worldCtx end,
        GetGameplayStatics = function() return statics end,
        GetPlayerController = function() return nil end,
    }
end

local function fakeVec(x, y, z) return { X = x, Y = y, Z = z } end
local function namedClass(name)
    local fname = obj({ ToString = function() return name end })
    return obj({ GetFName = function() return fname end })
end

-- UE4SS hands by-value USTRUCT params back as opaque userdata: readable enough
-- to hand straight to another UFunction call (which is all the replay needs),
-- useless for field access.
local function structParam(tag)
    local opaque = { __opaque = tag }
    return { get = function() return opaque end }
end

_G.RegisterHook = function(path, pre, post) hooks[path] = { pre = pre, post = post } end
_G.NotifyOnNewObject = function(classPath, cb) newObjectHooks[classPath] = cb end
_G.RegisterCustomProperty = function() return true end
_G.PropertyTypes = { Int64Property = 1 }
_G.FindAllOf = function(className)
    if className == "R5LootableInventoryBox" then return _G.__chests end
    if className == "R5BuildingBlock_BuildingCenter" then return _G.__centers or {} end
    return {}
end
_G.ExecuteWithDelay = function(ms, fn) delays[#delays + 1] = { ms = ms, fn = fn } end
_G.ExecuteInGameThread = function(fn) fn() end
_G.LoopAsync = function() end
_G.FText = function() return obj({}) end
_G.FName = function() return obj({}) end
_G.Key = setmetatable({}, { __index = function() return 1 end })
_G.ModifierKey = setmetatable({}, { __index = function() return 0 end })

--------------------------------------------------------------------- fake world
_G.__writeLog = {}
local nextAddr = 0x7F0000000000
local function newAddr()
    nextAddr = nextAddr + 0x100
    return nextAddr
end

local function makeChest(x, y, z, nodeId)
    local addr = newAddr()
    local chest = obj({
        GetAddress = function() return addr end,
        K2_GetActorLocation = function() return fakeVec(x, y, z) end,
        BuildingGraphNodeId = nodeId or 7,
    })
    local comp = obj({})
    -- Separate backing table: __newindex only fires while a key is absent, so the
    -- component cannot store its own values if the owner-pointer writes are to be
    -- observable here.
    local compStore = {}
    setmetatable(comp, {
        __index = function(_, k)
            local v = compStore[k]
            if v ~= nil then return v end
            if k == "IsValid" then return function() return not compStore.__dead end end
            return nil
        end,
        __newindex = function(_, k, v)
            if k == "CDR_CompProbe_A8" then _G.__writeLog[#_G.__writeLog + 1] = v end
            compStore[k] = v
        end,
    })
    for ofs = 0x28, 0x118, 8 do comp[string.format("CDR_CompProbe_%X", ofs)] = 0 end
    comp["CDR_CompProbe_A8"] = addr
    chest.InteractTargetComponent = comp
    return chest, comp
end

-- Camp 1 (node 11-19) holds the origin and five siblings; camp 2 (node 21-29) is a
-- neighbouring camp inside the same radius.
local originChest = makeChest(100, 0, 0, 11)
local sameCamp = {}
for i = 1, 5 do sameCamp[i] = makeChest(1100 + i * 100, 0, 0, 11 + i) end
local otherCamp = {}
for i = 1, 8 do otherCamp[i] = makeChest(2500 + i * 100, 0, 0, 21 + i) end
_G.__chests = { originChest }
for _, c in ipairs(sameCamp) do _G.__chests[#_G.__chests + 1] = c end
for _, c in ipairs(otherCamp) do _G.__chests[#_G.__chests + 1] = c end

local campIds = {}
for _, id in ipairs({ 11, 12, 13, 14, 15, 16 }) do campIds[id] = true end
_G.__centers = { obj({ StorageCenter = obj({
    BuildingGraphIds = obj({ Contains = function(_, id) return campIds[id] == true end }),
}) }) }

-- Player state, its ASC, and the avatar the mod locates through it.
local playerStateAddr = 0x7000001
local playerState = obj({ GetAddress = function() return playerStateAddr end })
local avatarAddr = 0xABC000
local avatar = obj({
    GetAddress = function() return avatarAddr end,
    K2_GetActorLocation = function() return fakeVec(150, 0, 0) end,
})
local ascCalls = 0
local asc = obj({
    AvatarActor = avatar,
    GetOwner = function() return playerState end,
    ServerSetReplicatedTargetData = function() ascCalls = ascCalls + 1 end,
})

--------------------------------------------------------------------- load
os.execute(string.format("cp %q %q", repoRoot .. "/src/main.lua", HERE .. "/main.lua"))
local cfg = io.open(HERE .. "/CampDepositReloaded.cfg.lua", "w")
-- DEPOSIT_CLASSES_STALE simulates a game update renaming the option class: the
-- allowlist no longer matches anything and the mod must say so instead of going
-- quietly inert.
local classesLine = flag("DEPOSIT_CLASSES_STALE")
    and 'depositOptionClasses = { R5Ability_InteractOption_DepositSimilarOld_C = true },'
    or ''
cfg:write(string.format(
    'return { enabled = true, debug = %s, runtimeLogging = true, replayMode = "unwrapped", debounceSeconds = 1.0, %s }',
    flag("DEBUG") and "true" or "false", classesLine))
cfg:close()

local realPrint = print
_G.__captured = {}
_G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts)
    _G.__captured[#_G.__captured + 1] = line
    realPrint(line)
end
local loaded, loadErr = pcall(dofile, HERE .. "/main.lua")
_G.print = realPrint
if not loaded then print("LOAD FAILED: " .. tostring(loadErr)) os.exit(1) end
print("load ok")

--------------------------------------------------------------------- driving
local hook = hooks["/Script/GameplayAbilities.AbilitySystemComponent:ServerSetReplicatedTargetData"]
assert(hook, "main hook not registered")
assert(newObjectHooks["/Script/R5.R5Ability_InteractOption_Base"], "option capture not registered")

local optionCounter = 0
local function constructOption(className, outer)
    optionCounter = optionCounter + 1
    newObjectHooks["/Script/R5.R5Ability_InteractOption_Base"](obj({
        GetAddress = function() return 0x900000 + optionCounter end,
        GetClass = function() return namedClass(className) end,
        GetOuter = function() return outer end,
    }))
end

local delayCursor = 0
local function drain()
    local rounds = 0
    while delayCursor < #delays and rounds < 400 do
        delayCursor = delayCursor + 1
        local d = delays[delayCursor]
        if d.ms == 15000 then goto continue end -- the debug summary, not a chunk
        d.fn()
        rounds = rounds + 1
        ::continue::
    end
end

local function writeViolations()
    local violations, alternating = 0, #_G.__writeLog > 0
    for i = 1, #_G.__writeLog do
        local isOrigin = _G.__writeLog[i] == originChest:GetAddress()
        if isOrigin ~= ((i % 2) == 0) then violations = violations + 1 end
    end
    return violations, alternating
end

local results = {}
_G.__captured = _G.__captured or {}
local function check(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok, detail = detail }
    print(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail and (" - " .. detail) or ""))
end

-- Simulates one real interaction: the game constructs the option ability, then
-- the target-data RPC lands ~2 ms later.
local function interact(className, deltaSeconds)
    clock = clock + (deltaSeconds or 0.4)
    constructOption(className, playerState)
    local ok, err = pcall(hook.post, { get = function() return asc end },
        structParam("handle"), structParam("origKey"), structParam("targetData"),
        structParam("appTag"), structParam("predKey"))
    drain()
    return ok, err
end

--------------------------------------------------------------------- scenarios
-- 1. Deposit Similar: the only interaction that may fan out.
_G.__writeLog, ascCalls = {}, 0
local ok, err = interact("GA_InteractOption_DepositSimilar_C")
check("deposit fans out", ok and err == nil and ascCalls == 5,
    string.format("replayed %d of 5 camp chests", ascCalls))
local violations, alternating = writeViolations()
check("owner pointer restored after every replay", violations == 0 and alternating,
    string.format("%d writes, %d violations", #_G.__writeLog, violations))

-- 2. Door: must not fan out, and must not disturb the component.
_G.__writeLog, ascCalls = {}, 0
local doorOk, doorErr = interact("R5Ability_InteractOption_ToggleDoor")
check("door does not fan out", doorOk and ascCalls == 0,
    string.format("replayed %d%s", ascCalls, doorErr and (" err=" .. tostring(doorErr)) or ""))
check("door writes nothing", #_G.__writeLog == 0, string.format("%d writes", #_G.__writeLog))

-- 3. Chest open / loot: must not fan out either.
_G.__writeLog, ascCalls = {}, 0
local chestOk, chestErr = interact("GA_InteractWithObject_ExternalInvetory_C")
check("chest open does not fan out", chestOk and ascCalls == 0,
    string.format("replayed %d%s", ascCalls, chestErr and (" err=" .. tostring(chestErr)) or ""))

-- 4. A deposit right after a loot must still work (report #3): the cooldown is
--    stamped only by real fan-outs, so the blocked interactions cost nothing.
_G.__writeLog, ascCalls = {}, 0
interact("GA_InteractWithObject_ExternalInvetory_C")
local lootOk = interact("GA_InteractOption_DepositSimilar_C", 0.1)
check("deposit straight after looting still fans out", lootOk and ascCalls == 5,
    string.format("replayed %d", ascCalls))

-- 5. No option observed at all (e.g. a dedicated server that constructs none):
--    fail closed means nothing happens.
_G.__writeLog, ascCalls = {}, 0
clock = clock + 10
local okNoOption = pcall(hook.post, { get = function() return asc end },
    structParam("handle"), structParam("origKey"), structParam("targetData"),
    structParam("appTag"), structParam("predKey"))
check("no option observed -> fail closed", okNoOption and ascCalls == 0,
    string.format("replayed %d", ascCalls))

-- 6. Another player's option must not authorise this player's deposit.
_G.__writeLog, ascCalls = {}, 0
clock = clock + 10
local otherState = obj({ GetAddress = function() return 0x7000002 end })
constructOption("GA_InteractOption_DepositSimilar_C", otherState)
local okOther = pcall(hook.post, { get = function() return asc end },
    structParam("handle"), structParam("origKey"), structParam("targetData"),
    structParam("appTag"), structParam("predKey"))
check("another player's option does not authorise", okOther and ascCalls == 0,
    string.format("replayed %d", ascCalls))

-- 7. A stale option (long after the interaction) must not authorise either.
_G.__writeLog, ascCalls = {}, 0
interact("GA_InteractOption_DepositSimilar_C") -- stamps a fresh entry
clock = clock + 5 -- past optionWindowSeconds
ascCalls = 0
local okStale = pcall(hook.post, { get = function() return asc end },
    structParam("handle"), structParam("origKey"), structParam("targetData"),
    structParam("appTag"), structParam("predKey"))
check("stale option does not authorise", okStale and ascCalls == 0, string.format("replayed %d", ascCalls))

-- 8. Camp scoping: the neighbouring camp must never be a target.
local inOtherCamp = 0
for _, chest in ipairs(_G.__chests) do
    if chest.BuildingGraphNodeId >= 21 then inOtherCamp = inOtherCamp + 1 end
end
check("neighbouring camp excluded", ascCalls == 0 and inOtherCamp == 8,
    string.format("%d chests in the other camp, none targeted", inOtherCamp))

-- 9. If the allowlist stops matching (a renamed option class after a game
--    update), the mod must warn once rather than silently doing nothing.
if flag("DEPOSIT_CLASSES_STALE") then
    -- The game still constructs the current class; only the config is stale.
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts)
        _G.__captured[#_G.__captured + 1] = line
        realPrint(line)
    end
    for _ = 1, 25 do interact("GA_InteractOption_DepositSimilar_C", 0.1) end
    _G.print = realPrint
    local warnings = 0
    for _, line in ipairs(_G.__captured) do
        if line:find("no fan%-out in") then warnings = warnings + 1 end
    end
    check("renamed class warns once", warnings == 1 and ascCalls == 0,
        string.format("%d warning(s) over 25 interactions, %d replays", warnings, ascCalls))
    return
end

--------------------------------------------------------------------- result
local failed = 0
for _, r in ipairs(results) do
    if not r.ok then failed = failed + 1 end
end
print(string.format("\n%d checks, %d failed", #results, failed))
os.exit(failed == 0 and 0 or 1)
