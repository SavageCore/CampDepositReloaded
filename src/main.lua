-- CampDepositReloaded: extends vanilla "Deposit Similar" to nearby camp
-- chests. Server-side mod - no client install needed.
local VERSION = "0.0.0"

local CONFIG_PATH = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "") .. "CampDepositReloaded.cfg.lua"

local config = {
    enabled = true,
    radiusMeters = 48.0,
    maxAttempts = 16,
    runtimeLogging = true,
    debug = false, -- verbose per-deposit tracing, for diagnosing a silent failure
}

local function log(fmt, ...)
    if config.runtimeLogging then
        print(("[CampDepositReloaded] " .. fmt .. "\n"):format(...))
    end
end

local function trace(fmt, ...)
    if config.debug then log("[debug] " .. fmt, ...) end
end

local function loadConfig()
    local f = io.open(CONFIG_PATH, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    local chunk, chunkErr = load(content, "CampDepositReloadedConfig", "t", {})
    if not chunk then
        log("config load error: %s", chunkErr)
        return
    end
    local ok, cfg = pcall(chunk)
    if not ok or type(cfg) ~= "table" then
        log("config load error: %s", tostring(cfg))
        return
    end
    for k, v in pairs(cfg) do
        if config[k] ~= nil and type(v) == type(config[k]) then
            config[k] = v
        end
    end
end

loadConfig()

local CAMP_CHEST_CLASS = "R5LootableInventoryBox"

local function addressOf(obj)
    local ok, addr = pcall(function() return obj:GetAddress() end)
    if not ok then return nil end
    return addr
end

local function sameObject(a, b)
    local addrA, addrB = addressOf(a), addressOf(b)
    return addrA ~= nil and addrA == addrB
end

local function actorLocation(actor)
    local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if not ok then return nil end
    return loc
end

local function distance(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Camp chests within config.radiusMeters of originLoc, nearest first, capped
-- at config.maxAttempts.
local function nearbyChests(origin, originLoc)
    local ok, boxes = pcall(function() return FindAllOf(CAMP_CHEST_CLASS) end)
    if not ok or not boxes then return {} end
    local candidates = {}
    for _, box in ipairs(boxes) do
        if box:IsValid() and not sameObject(box, origin) then
            local loc = actorLocation(box)
            local d = loc and distance(originLoc, loc) or nil
            if d and d <= config.radiusMeters * 100.0 then -- uu per meter
                table.insert(candidates, { box = box, d = d })
            end
        end
    end
    table.sort(candidates, function(a, b) return a.d < b.d end)
    local out = {}
    for i = 1, math.min(#candidates, config.maxAttempts) do out[i] = candidates[i].box end
    return out
end

-- The deposit's destination is resolved server-side through the interact
-- component's owning actor, not through the (opaque) replicated target data.
-- No reflected owner property exists, so its offset in UActorComponent is
-- discovered at runtime instead of hardcoded, to survive a game update.
local COMP_PROBE_OFFSETS = {}
for ofs = 0x28, 0x118, 8 do table.insert(COMP_PROBE_OFFSETS, ofs) end

local probesRegistered = false
local function registerProbes()
    local ok, err = pcall(function()
        for _, ofs in ipairs(COMP_PROBE_OFFSETS) do
            RegisterCustomProperty({
                ["Name"] = string.format("CDR_CompProbe_%X", ofs),
                ["Type"] = PropertyTypes.Int64Property,
                ["BelongsToClass"] = "/Script/Engine.ActorComponent",
                ["OffsetInternal"] = ofs,
            })
        end
    end)
    probesRegistered = ok
    if not ok then
        log("RegisterCustomProperty failed, mod cannot function: %s", tostring(err))
    end
end

local function readCompProbe(comp, ofs)
    local ok, v = pcall(function() return comp[string.format("CDR_CompProbe_%X", ofs)] end)
    if not ok then return nil end
    return tonumber(v)
end

local function writeCompProbe(comp, ofs, value)
    return (pcall(function() comp[string.format("CDR_CompProbe_%X", ofs)] = value end))
end

local function interactComponentOf(chest)
    local ok, comp = pcall(function() return chest.InteractTargetComponent end)
    if ok and comp and comp:IsValid() then return comp end
    return nil
end

-- Offsets in comp whose qword equals ownerAddr - the owner pointer location(s).
local function findOwnerOffsets(comp, ownerAddr)
    local hits = {}
    for _, ofs in ipairs(COMP_PROBE_OFFSETS) do
        if readCompProbe(comp, ofs) == ownerAddr then table.insert(hits, ofs) end
    end
    return hits
end

-- The pawn behind an ASC, trying property, getter, then PlayerState.
local function avatarOfASC(asc)
    local ok, a = pcall(function() return asc.AvatarActor end)
    if ok and a and a:IsValid() then return a end
    ok, a = pcall(function() return asc:GetAvatarActor() end)
    if ok and a and a:IsValid() then return a end
    ok, a = pcall(function() return asc:GetOwner():GetPawn() end)
    if ok and a and a:IsValid() then return a end
    return nil
end

-- Deposit Similar reaches the server as one call: ServerSetReplicatedTargetData
-- on the player's ASC. Hooked POST so the player's own deposit runs first. For
-- each other nearby chest, point the origin chest's component owner at it and
-- re-fire the same RPC - the server re-resolves the destination through the
-- lied-about component and deposits again. inMultipass guards against our own
-- re-fire recursing into this hook. Origin is approximated as the chest
-- nearest the player, since the replicated payload doesn't expose it.
local inMultipass = false

local function runMultipass(asc, pAbilityHandle, pOrigKey, pTargetData, pAppTag, pCurKey)
    trace("hook fired")
    local avatar = avatarOfASC(asc)
    local loc = avatar and actorLocation(avatar) or nil
    if not loc then
        trace("no avatar/location resolved, stopping"); return
    end

    local ok, boxes = pcall(function() return FindAllOf(CAMP_CHEST_CLASS) end)
    if not ok or not boxes then
        trace("FindAllOf(%s) failed: %s", CAMP_CHEST_CLASS, tostring(boxes)); return
    end
    local origin, originDist = nil, math.huge
    for _, box in ipairs(boxes) do
        if box:IsValid() then
            local bl = actorLocation(box)
            local d = bl and distance(loc, bl) or math.huge
            if d < originDist then origin, originDist = box, d end
        end
    end
    if not origin then
        trace("no origin chest found near player"); return
    end
    trace("origin chest %.1fm from player", originDist / 100.0)

    local comp = interactComponentOf(origin)
    local originAddr = addressOf(origin)
    if not comp then
        trace("origin chest has no InteractTargetComponent"); return
    end
    local offsets = findOwnerOffsets(comp, originAddr)
    if #offsets == 0 then
        log("could not locate the interact component's owner pointer, skipping multipass")
        return
    end

    local targets = nearbyChests(origin, loc)
    if #targets == 0 then
        trace("no other chests in range"); return
    end
    trace("%d target chest(s) in range", #targets)

    local handle, td, tag = pAbilityHandle:get(), pTargetData:get(), pAppTag:get()
    local origKey, curKey = pOrigKey:get(), pCurKey:get()

    inMultipass = true
    local sent = 0
    for _, chest in ipairs(targets) do
        if comp:IsValid() and chest:IsValid() then
            for _, ofs in ipairs(offsets) do writeCompProbe(comp, ofs, addressOf(chest)) end
            local rOk = pcall(function()
                asc:ServerSetReplicatedTargetData(handle, origKey, td, tag, curKey)
            end)
            if rOk then sent = sent + 1 end
        end
    end
    if comp:IsValid() then
        for _, ofs in ipairs(offsets) do writeCompProbe(comp, ofs, originAddr) end
    end
    inMultipass = false

    if sent > 0 then
        log("deposited into %d nearby chest(s)", sent)
    end
end

-- Extra hooks armed only by config.debug, to find which call (if any) a
-- networked deposit actually reaches when ServerSetReplicatedTargetData
-- itself doesn't fire - e.g. a listen-server host's own deposit.
local DEBUG_RPC_CANDIDATES = {
    "/Script/GameplayAbilities.AbilitySystemComponent:ServerTryActivateAbility",
    "/Script/GameplayAbilities.AbilitySystemComponent:ServerTryActivateAbilityWithEventData",
    "/Script/GameplayAbilities.AbilitySystemComponent:ServerSetReplicatedEvent",
    "/Script/GameplayAbilities.AbilitySystemComponent:ServerAbilityRPCBatch",
    "/Script/R5.R5Ability_Interact:OnInteractRequestEventReceived",
}

local function registerDebugDiagnostics()
    for _, path in ipairs(DEBUG_RPC_CANDIDATES) do
        pcall(function()
            RegisterHook(path, function() trace("FIRED %s", path) end)
        end)
    end
    pcall(function()
        NotifyOnNewObject("/Script/R5.R5Ability_InteractOption_Base", function(opt)
            local ok, name = pcall(function() return opt:GetClass():GetFName():ToString() end)
            trace("interact-option constructed: %s", ok and name or "?")
        end)
    end)
    trace("extra RPC diagnostics armed")
end

if config.enabled then
    registerProbes()
    if config.debug then registerDebugDiagnostics() end
    if probesRegistered then
        RegisterHook(
            "/Script/GameplayAbilities.AbilitySystemComponent:ServerSetReplicatedTargetData",
            function() end,
            function(context, pAbilityHandle, pOrigKey, pTargetData, pAppTag, pCurKey)
                trace("ServerSetReplicatedTargetData observed (inMultipass=%s)", tostring(inMultipass))
                if inMultipass then return end
                local ok, err = pcall(function()
                    runMultipass(context:get(), pAbilityHandle, pOrigKey, pTargetData, pAppTag, pCurKey)
                end)
                if not ok then log("multipass error: %s", tostring(err)) end
            end
        )
    end
    log("v%s loaded - radius %.0fm, max attempts %d", VERSION, config.radiusMeters, config.maxAttempts)
else
    log("v%s loaded but disabled via config", VERSION)
end
