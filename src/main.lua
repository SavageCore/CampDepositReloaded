-- CampDepositReloaded: extends vanilla "Deposit Similar" to nearby camp
-- chests. Server-side mod - no client install needed.
local VERSION = "0.1.1"
local UEHelpers = require("UEHelpers")

local CONFIG_PATH = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "") .. "CampDepositReloaded.cfg.lua"

local config = {
    enabled = true,
    radiusMeters = 48.0,
    maxAttempts = 16,
    chestsPerTick = 4, -- max replays per frame, so a fan-out cannot stall a frame
    campScoped = true, -- limit targets to the origin chest's camp when it has one
    interactRangeMeters = 6.0, -- origin chest must be this close to the player
    debounceSeconds = 1.0, -- min gap between fan-outs for the same player
    runtimeLogging = true,
    -- Classes whose interact option ability means "this was a Deposit Similar".
    -- The Blueprint class is the one the game actually constructs; the native
    -- class is listed too in case a future update stops wrapping it.
    depositOptionClasses = {
        GA_InteractOption_DepositSimilar_C = true,
        R5Ability_InteractOption_DepositSimilar = true,
    },
    optionWindowSeconds = 1.0, -- how recent that option must be to count
    failClosed = true, -- an interaction we cannot identify is one we do not touch
    debug = false, -- verbose tracing + interaction diagnostics (see TESTING.md)
    -- What the replayed RPC gets for its by-value FGameplayAbilityTargetDataHandle:
    -- "unwrapped" hands over pTargetData:get() and works; "wrapper" hands over the
    -- raw RemoteUnrealParam and the engine rejects it on every call. Untested values
    -- fall back to "unwrapped".
    replayMode = "unwrapped",
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

local REPLAY_MODES = { wrapper = true, unwrapped = true }
if not REPLAY_MODES[config.replayMode] then
    log("unknown replayMode '%s', falling back to 'unwrapped'", tostring(config.replayMode))
    config.replayMode = "unwrapped"
end

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

-- One sweep over every loaded camp chest, answering both questions a fan-out
-- needs: which chest is the player standing at (the origin candidate), and
-- which other chests are in range. The previous code called FindAllOf twice per
-- run and walked the whole class each time, so on a warehouse base (report #1,
-- ~122 chests) every single interaction - door, window, opening a chest, looting
-- - paid for two full sweeps before the mod could decide it had nothing to do.
--
-- Returns the nearest chest with its distance, plus the in-radius candidates
-- sorted nearest first.
local function scanChests(originLoc)
    local ok, boxes = pcall(function() return FindAllOf(CAMP_CHEST_CLASS) end)
    if not ok or not boxes then return nil, nil, {} end
    local radius = config.radiusMeters * 100.0 -- uu per meter
    local nearest, nearestDist, candidates = nil, nil, {}
    for _, box in ipairs(boxes) do
        if box:IsValid() then
            local loc = actorLocation(box)
            local d = loc and distance(originLoc, loc) or nil
            if d then
                if not nearestDist or d < nearestDist then nearest, nearestDist = box, d end
                if d <= radius then candidates[#candidates + 1] = { box = box, d = d } end
            end
        end
    end
    table.sort(candidates, function(a, b) return a.d < b.d end)
    return nearest, nearestDist, candidates
end

-- Camp scoping: chests belong to a building graph, and a camp's building centre
-- carries the ids of every chest in it (R5BuildingCenterStorageComponent:
-- BuildingGraphIds). SmartStorage relies on the same path to keep its fan-out
-- inside one camp. Resolving it costs a FindAllOf of the (few) building centres,
-- so the result is cached per chest address - a fan-out is all for one origin.
local CAMP_CENTER_CLASS = "R5BuildingBlock_BuildingCenter"
local campCenterCache = {} -- chest address -> storage centre component | false

local function storageCenterOf(center)
    local ok, storageCenter = pcall(function() return center.StorageCenter end)
    if ok and storageCenter and storageCenter:IsValid() then return storageCenter end
    return nil
end

local function inCamp(storageCenter, chest)
    if not storageCenter then return false end
    local idOk, nodeId = pcall(function() return chest.BuildingGraphNodeId end)
    if not idOk then return false end
    local containsOk, contains = pcall(function()
        return storageCenter.BuildingGraphIds:Contains(nodeId)
    end)
    return containsOk and contains or false
end

-- The storage centre owning this chest, or nil when the chest belongs to no
-- known building centre (a lone chest, or a camp laid out without one).
local function campOf(chest)
    local addr = addressOf(chest)
    if not addr then return nil end
    local cached = campCenterCache[addr]
    if cached ~= nil then
        return cached or nil
    end
    local found
    local ok, centers = pcall(function() return FindAllOf(CAMP_CENTER_CLASS) end)
    if ok and centers then
        for _, center in ipairs(centers) do
            if inCamp(storageCenterOf(center), chest) then
                found = storageCenterOf(center)
                break
            end
        end
    end
    campCenterCache[addr] = found or false
    return found
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

-- lastFanoutAt is a *cooldown*, not a filter: it is stamped only when a fan-out
-- actually starts, so the many interactions that reach this hook never consume
-- the window a real Deposit Similar needs. Report #3 (a deposit straight after
-- looting silently doing nothing) was exactly that: the old code stamped the
-- timestamp on every interaction it saw, whether or not it fanned out.
local lastFanoutAt = {} -- avatar address -> world time of last fan-out start


-- Game/world time in seconds, not os.clock() (CPU time on some platforms).
-- Mirrors CozyBonfire's GetWorldTime: GetWorld() has no local player to key
-- off on a dedicated server, so GameModeBase is the fallback world context.
local function worldTime()
    local ok, t = pcall(function()
        return UEHelpers.GetGameplayStatics():GetTimeSeconds(UEHelpers.GetWorld())
    end)
    if ok and type(t) == "number" then return t end
    ok, t = pcall(function()
        return UEHelpers.GetGameplayStatics():GetTimeSeconds(UEHelpers.GetGameModeBase())
    end)
    if ok and type(t) == "number" then return t end
    return nil
end

-- Set while we are replaying the captured RPC for our own targets, so our own
-- re-fire (and the interact-option construction it provokes) does not recurse
-- back into the hook. Declared ahead of the diagnostics block because those
-- probes consult it too.
local inMultipass = false

-- ============================================================
-- Diagnostics
--
-- Everything below is inert unless config.debug is true. Its job is to answer,
-- from one test session in the game, the questions the SDK dump cannot settle:
-- which server-side calls a Deposit Similar makes versus a door or a loot
-- pickup, whether the RPC's inner struct fields are readable, whether the
-- interact option ability is constructed per interaction, and whether handing
-- the replayed RPC an unwrapped or a wrapped target-data argument survives.
--
-- Counters plus one bail reason per early return keep a silent no-op
-- explainable from UE4SS.log, which is the whole point: report #3 (deposit
-- silently skipped) was undiagnosable because nothing said why the mod stayed
-- quiet.
-- ============================================================

local diag = { counters = {} }

local function count(key, by)
    diag.counters[key] = (diag.counters[key] or 0) + (by or 1)
end

-- Ends a run without doing any work, and records why.
local function bail(reason, ...)
    count("skip:" .. reason)
    local detail = ""
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, ...)
        detail = ok and (": " .. formatted) or ": <bad format>"
    end
    trace("skipped (%s)%s", reason, detail)
    return true
end

local function classNameOf(obj)
    if obj == nil then return "nil" end
    local ok, name = pcall(function() return obj:GetClass():GetFName():ToString() end)
    if ok and name then return tostring(name) end
    local fullOk, full = pcall(function() return obj:GetFullName() end)
    if fullOk and type(full) == "string" then return full:match("^([^ ]+)") or "?" end
    return "?"
end

local function describeObject(obj)
    if obj == nil then return "nil" end
    local ok, valid = pcall(function() return obj:IsValid() end)
    if not ok then return tostring(obj) end
    if not valid then return "<invalid>" end
    local nameOk, name = pcall(function() return obj:GetFullName() end)
    if nameOk and type(name) == "string" then return name end
    return classNameOf(obj)
end

-- Debug-only summary of the origin chest's camp: node id, storage centre, and
-- how many chests that camp holds. Camp scoping is the default, so when a fan-out
-- reaches fewer chests than expected this is the first line to look at.
local function describeCamp(chest)
    local nodeOk, nodeId = pcall(function() return chest.BuildingGraphNodeId end)
    if not nodeOk then return "node=<unreadable>" end
    local storageCenter = campOf(chest)
    if not storageCenter then return string.format("node=%s camp=<none>", tostring(nodeId)) end
    local campChests = 0
    local boxesOk, boxes = pcall(function() return FindAllOf(CAMP_CHEST_CLASS) end)
    if boxesOk and boxes then
        for _, box in ipairs(boxes) do
            if box:IsValid() and inCamp(storageCenter, box) then campChests = campChests + 1 end
        end
    end
    return string.format("node=%s camp=%s campChests=%d",
        tostring(nodeId), classNameOf(storageCenter), campChests)
end

-- ============================================================
-- Interaction identity
--
-- ServerSetReplicatedTargetData is the generic targeted-interact path, not a
-- deposit path. Measured on this build (2026-10-02, singleplayer, debug log):
-- the same hook fires for a deposit, for opening and closing a door, and for
-- opening and looting a chest, and it replayed a fan-out every time.
--
-- The identity lives one step earlier. Every interaction constructs an interact
-- option ability, its class names the action, and it is constructed ~2 ms before
-- the RPC arrives:
--
--   deposit        GA_InteractOption_DepositSimilar_C
--   door           R5Ability_InteractOption_ToggleDoor
--   chest open     GA_InteractWithObject_ExternalInvetory_C
--
-- The option's GetOuter() is the player's BP_R5PlayerState_C - the same object
-- that owns the AbilitySystemComponent carrying the RPC - so the two match per
-- player rather than globally.
--
-- Rejected alternatives, all measured rather than assumed:
--   - the RPC's own by-value params (handle, prediction key, ApplicationTag) come
--     back from UE4SS as opaque UScriptStruct userdata, so none of their fields
--     are readable;
--   - R5Ability_InteractOption_Base:GetTargetActor is hookable and fires per
--     interaction, but its return value reads back invalid, so it cannot supply
--     an exact origin chest;
--   - R5InteractionTargetModel:GetInteractionOptions returns an empty array here.
--
-- So: capture the option, key it by player, and refuse to fan out unless it says
-- deposit. Fail closed - an interaction we cannot identify is one we do not
-- touch.
-- ============================================================

local optionByPlayer = {} -- player state address -> { className, at }
local GATE_CHECKS_UNTIL_WARNED = 20
local gateChecks = 0 -- consecutive gate failures
local seenGateReasons = {} -- distinct block reasons, listed in the one-shot warning

local function gateReasonList()
    local reasons = {}
    for reason in pairs(seenGateReasons) do reasons[#reasons + 1] = reason end
    table.sort(reasons)
    return reasons
end

-- Registers the option constructor. Cheap: one class-name read and one
-- world-time read per interaction. Class names are deliberately not cached by
-- address - the saving is negligible and a destroyed ability's address being
-- reused by a different class would mislabel it.
local function registerInteractOptionCapture()
    NotifyOnNewObject("/Script/R5.R5Ability_InteractOption_Base", function(option)
        if not option or not option:IsValid() then return end
        count("option-constructed")

        local className = classNameOf(option)
        local outerOk, outer = pcall(function() return option:GetOuter() end)
        local outerAddr = outerOk and addressOf(outer) or nil
        if outerAddr then
            optionByPlayer[outerAddr] = { className = className, at = worldTime() }
        end
        trace("interact option: class=%s player=%s", className, outerOk and describeObject(outer) or "?")
    end)
end

-- True only when this ASC's own player just constructed a Deposit Similar
-- option. Anything unverifiable - no option seen, a stale one, an option for
-- another player, an unknown class - returns false plus the reason.
local function isDepositInteraction(asc)
    local ownerOk, owner = pcall(function() return asc:GetOwner() end)
    if not ownerOk then return false, "asc-owner-unreadable" end
    local ownerAddr = addressOf(owner)
    if not ownerAddr then return false, "asc-owner-address" end

    local entry = optionByPlayer[ownerAddr]
    if not entry then return false, "no-option-for-this-player" end

    local now = worldTime()
    if now and entry.at and (now - entry.at) > config.optionWindowSeconds then
        return false, "option-stale"
    end
    if not config.depositOptionClasses[entry.className] then
        return false, "option-is-" .. entry.className
    end
    return true, entry.className
end

local SUMMARY_INTERVAL_MS = 15000

-- Replays can fail 16 times in a row; report the first few reasons rather than
-- every one, or a bad pass floods the log and buries everything else.
local MAX_REPLAY_ERRORS_LOGGED = 3
local replayErrorsLogged = 0

local function startDiagnosticSummary()
    local function publish()
        local keys = {}
        for key in pairs(diag.counters) do keys[#keys + 1] = key end
        table.sort(keys)
        local parts = {}
        for _, key in ipairs(keys) do
            parts[#parts + 1] = string.format("%s=%d", key, diag.counters[key])
        end
        local optionState = "none seen"
        for _, entry in pairs(optionByPlayer) do
            optionState = entry.className -- any player is enough for a debug line
            if optionState ~= "none seen" then break end
        end
        trace("summary: %s | options seen: %s | gate blocks: %s",
            table.concat(parts, " "), optionState, table.concat(gateReasonList(), ","))
        ExecuteWithDelay(SUMMARY_INTERVAL_MS, publish)
    end
    ExecuteWithDelay(SUMMARY_INTERVAL_MS, publish)
end

-- Deposit Similar reaches the server as one call: ServerSetReplicatedTargetData
-- on the player's ASC. Hooked POST so the player's own deposit runs first. For
-- each other nearby chest, point the origin chest's component owner at it and
-- re-fire the same RPC - the server re-resolves the destination through the
-- lied-about component and deposits again. Origin is approximated as the chest
-- nearest the player, since the replicated payload doesn't expose it.

-- The replay job: a queue of target chests plus everything needed to fire them.
-- Processed over several frames (see runJob) so one Deposit Similar cannot
-- stall a server frame with a burst of full native deposit passes.
local activeJob = nil

local CHUNK_DELAY_SECONDS = 0.001
-- Frame slicing depends on ExecuteWithDelay actually firing. If a chunk callback
-- is ever dropped - mod reload, a hitch longer than the delay - the job would sit
-- in activeJob forever and every later interaction would be rejected as busy. So
-- a job is force-finished if it outlives its watchdog.
local JOB_WATCHDOG_SECONDS = 5.0

-- One chest, fully undone before returning: write the owner pointer, replay the
-- captured RPC, then restore and verify. The lie must never survive the call,
-- because anything else processed in between (another player's interaction, the
-- game's own tick) would resolve its destination through it. Verifying the
-- restore, and aborting the job if it did not take, follows SmartStorage's
-- read-back check - a chest permanently pointing at the wrong owner would be far
-- worse than a fan-out that stops early.
local function replayInto(job, chest)
    local comp = job.comp
    if not (comp and comp:IsValid()) or not chest:IsValid() then
        return false, nil
    end

    local targetAddr = addressOf(chest)
    if not targetAddr or not writeCompProbe(comp, job.ownerOffset, targetAddr) then
        return false, nil
    end

    -- Suppress only around our own call: our re-fire re-enters this hook, and
    -- nothing else should be swallowed by it. Earlier versions held the flag for
    -- the whole fan-out, which is what let one interaction suppress an unrelated
    -- one.
    inMultipass = true
    local rOk, rErr = pcall(function()
        job.asc:ServerSetReplicatedTargetData(
            job.handle, job.origKey, job.targetData, job.tag, job.curKey)
    end)
    inMultipass = false

    local restored = comp:IsValid() and writeCompProbe(comp, job.ownerOffset, job.originAddr)
    if not restored or readCompProbe(comp, job.ownerOffset) ~= job.originAddr then
        return false, "owner pointer not restored"
    end
    if not rOk then return false, rErr end
    return true, nil
end

local function finishJob(job)
    if activeJob == job then activeJob = nil end
    -- The authorising option class is named on every runtime line: with debug off
    -- this is the only way to see *which* interaction caused a fan-out, and a
    -- fan-out that was not a Deposit Similar is the exact failure that shipped
    -- unnoticed before.
    if job.replayed > 0 then
        log("replayed deposit into %d of %d nearby chest(s) [%s]",
            job.replayed, #job.targets, job.authorisedBy or "?")
    elseif job.lastError then
        log("no chest accepted a replay of %d target(s) (replayMode=%s, %s)",
            #job.targets, config.replayMode, job.authorisedBy or "?")
    end
end

-- Processes up to config.chestsPerTick targets per frame, then re-arms itself.
-- 16 native deposit passes in one frame is exactly the "server lags for a few
-- seconds" shape from report #1; four per frame is not.
local function runJob(job)
    if job.expired then return end
    -- Every chunk that actually runs pushes the deadline out. If one is ever
    -- dropped, the deadline lapses and the next interaction reaps the job instead
    -- of leaving it in activeJob forever.
    local started = worldTime()
    job.deadline = started and (started + JOB_WATCHDOG_SECONDS) or nil
    local attempted = 0
    while attempted < config.chestsPerTick and job.index <= #job.targets do
        local chest = job.targets[job.index]
        job.index = job.index + 1
        attempted = attempted + 1
        local replayed, replayErr = replayInto(job, chest)
        if replayed then
            job.replayed = job.replayed + 1
            count("replay-ok")
        elseif replayErr == "owner pointer not restored" then
            -- Stop rather than keep aiming a component we no longer control.
            count("replay-restore-failed")
            log("aborting fan-out: %s", replayErr)
            job.aborted = true
            job.lastError = replayErr
            break
        elseif replayErr then
            count("replay-error")
            -- Say what the engine objected to. A silent "0 of N" is how the dead
            -- replay mode shipped unnoticed in the first place.
            if replayErrorsLogged < MAX_REPLAY_ERRORS_LOGGED then
                replayErrorsLogged = replayErrorsLogged + 1
                log("replay rejected (replayMode=%s): %s", config.replayMode, tostring(replayErr))
            end
            job.lastError = replayErr
        else
            count("replay-skipped") -- target or component went invalid mid-job
        end
    end

    if job.index <= #job.targets and not job.aborted then
        ExecuteWithDelay(CHUNK_DELAY_SECONDS, function()
            ExecuteInGameThread(function() runJob(job) end)
        end)
        return
    end

    finishJob(job)
end

local function jobIsStale(job)
    if not job.deadline then return false end
    local now = worldTime()
    return now ~= nil and now > job.deadline
end

local function startJob(job)
    if activeJob then
        -- One fan-out at a time. The previous design could not reach this state
        -- (everything ran inside the hook), but frame slicing opens the door to
        -- overlapping jobs, so close it deliberately rather than by luck.
        count("skip:fanout-busy")
        return bail("fanout-busy")
    end
    activeJob = job
    count("fanout")
    runJob(job)
end

local function runMultipass(asc, pAbilityHandle, pOrigKey, pTargetData, pAppTag, pCurKey)
    count("rpc")
    -- Cheapest possible exit first: while a fan-out is in flight (a few frames),
    -- every other interaction - door, window, chest open, loot - should cost
    -- nothing at all rather than a full sweep over every chest. A job whose
    -- chunks stopped arriving is reaped here instead of blocking forever.
    if activeJob then
        if not jobIsStale(activeJob) then return bail("fanout-busy") end
        count("fanout-expired")
        log("abandoning a fan-out that stalled after %d of %d chest(s)",
            activeJob.replayed, #activeJob.targets)
        activeJob.expired = true
        finishJob(activeJob)
    end

    local avatar = avatarOfASC(asc)
    local loc = avatar and actorLocation(avatar) or nil
    if not loc then return bail("no-avatar") end

    -- The gate: only a Deposit Similar is fanned out. This is the difference
    -- between the mod working and the mod breaking doors - the same hook fires
    -- for doors, windows and chest opens, and every one of those used to replay a
    -- full fan-out, toggling the interactable once per target chest (report #2).
    local isDeposit, gateReason = isDepositInteraction(asc)
    local authorisedBy = isDeposit and gateReason or (config.failClosed and nil or "unverified")
    count("gate:" .. (isDeposit and "pass" or "block"))
    if not isDeposit and config.failClosed then
        if gateChecks >= GATE_CHECKS_UNTIL_WARNED then
            return bail("not-a-deposit", "%s", gateReason)
        end
        gateChecks = gateChecks + 1
        seenGateReasons[gateReason] = true
        if gateChecks == GATE_CHECKS_UNTIL_WARNED then
            -- Say so once rather than leaving the mod mysteriously inert: the
            -- usual cause is a game update renaming the Deposit Similar option.
            log("no fan-out in %d interactions (reasons: %s); "
                .. "check config.depositOptionClasses if the game renamed it",
                gateChecks, table.concat(gateReasonList(), ", "))
        end
        trace("not fanning out (%s)", gateReason)
        return bail("not-a-deposit", "%s", gateReason)
    end
    if not isDeposit then
        trace("fanning out without a confirmed identity (failClosed=%s)", tostring(config.failClosed))
    end

    -- The four params the replay has to hand back. Read them before the chest
    -- scan: if any of them is unreadable we cannot replay at all, and finding
    -- that out after a full sweep over every chest is wasted work.
    local gotHandle, handle = pcall(function() return pAbilityHandle:get() end)
    local gotTag, tag = pcall(function() return pAppTag:get() end)
    local gotOrigKey, origKey = pcall(function() return pOrigKey:get() end)
    local gotCurKey, curKey = pcall(function() return pCurKey:get() end)
    if not (gotHandle and gotTag and gotOrigKey and gotCurKey) then
        return bail("unreadable-rpc-params", "handle=%s appTag=%s origKey=%s curKey=%s",
            tostring(gotHandle), tostring(gotTag), tostring(gotOrigKey), tostring(gotCurKey))
    end

    local avatarAddr = addressOf(avatar)
    local now = worldTime()

    local origin, originDist, candidates = scanChests(loc)
    if not origin then return bail("no-origin-chest") end
    if originDist > config.interactRangeMeters * 100.0 then
        return bail("out-of-range", "nearest chest %.1fm away, interact range is %.1fm",
            originDist / 100.0, config.interactRangeMeters)
    end

    -- Stamp the cooldown only now that we know a fan-out is going to happen, so
    -- the doors and chest-opens that also reach this hook cannot eat a real
    -- deposit's window (report #3).
    if avatarAddr and now then
        local last = lastFanoutAt[avatarAddr]
        if last and (now - last) < config.debounceSeconds then
            return bail("cooldown", "%.2fs since last fan-out", now - last)
        end
        lastFanoutAt[avatarAddr] = now
    end

    local comp = interactComponentOf(origin)
    local originAddr = addressOf(origin)
    if not comp then return bail("no-interact-component") end
    trace("origin chest %.1fm from player, %s", originDist / 100.0, describeCamp(origin))
    local offsets = findOwnerOffsets(comp, originAddr)
    if #offsets == 0 then
        count("skip:no-owner-offset")
        log("could not locate the interact component's owner pointer, skipping multipass")
        return
    end
    -- A live UE4SS-vs-Windows crash traced back to this: writing to *every*
    -- offset that happens to currently hold originAddr is unsafe - if more
    -- than one field coincidentally matches, at least one write lands on a
    -- field that isn't actually the owner pointer and corrupts live engine
    -- memory. Only proceed when exactly one candidate is unambiguous.
    if #offsets > 1 then
        count("skip:ambiguous-owner-offset")
        log("owner pointer is ambiguous (%d candidate offsets), skipping multipass", #offsets)
        return
    end
    local ownerOffset = offsets[1]

    -- Targets: the origin's own camp when it has one, else plain radius. Camp
    -- scoping is the default because Deposit Similar's own behaviour is
    -- per-container, and on a map where two camps sit inside one radius the
    -- fan-out should not cross between them.
    local targets = {}
    local storageCenter = config.campScoped and campOf(origin) or nil
    if config.campScoped then
        if storageCenter then
            for _, candidate in ipairs(candidates) do
                if not sameObject(candidate.box, origin) and inCamp(storageCenter, candidate.box) then
                    targets[#targets + 1] = candidate.box
                end
            end
        else
            count("camp-unknown")
            trace("no building centre for this chest, falling back to radius")
        end
    end
    if #targets == 0 and not storageCenter then
        for _, candidate in ipairs(candidates) do
            if not sameObject(candidate.box, origin) then targets[#targets + 1] = candidate.box end
        end
    end
    -- Cap the queue last, after camp filtering, so the cap spends on the chests
    -- nearest the origin rather than on whatever the camp happened to yield.
    if #targets > config.maxAttempts then
        local capped = {}
        for i = 1, config.maxAttempts do capped[i] = targets[i] end
        targets = capped
    end
    if #targets == 0 then return bail("no-targets") end

    -- The by-value FGameplayAbilityTargetDataHandle is the one argument we cannot
    -- read (see the pTargetData comment below), and it is the one the replay
    -- turns on. config.replayMode picks which form to hand the engine:
    --
    --   "unwrapped" - pTargetData:get(), a plain Lua value. This is what released
    --     v0.1.0 passed and what SmartStorage ships, and it is what actually
    --     works: with "wrapper" the engine rejects every single call and the
    --     fan-out silently does nothing ("replayed deposit into 0 nearby
    --     chest(s)").
    --   "wrapper"   - the raw RemoteUnrealParam. Kept only so the earlier
    --     SIGSEGV hypothesis can be re-tested deliberately; it is not a
    --     working mode on this build.
    local targetDataArg = pTargetData
    if config.replayMode == "unwrapped" then
        local ok, unwrapped = pcall(function() return pTargetData:get() end)
        if ok then
            targetDataArg = unwrapped
        else
            count("replay-unavailable")
            return bail("replay-mode-unavailable", "pTargetData:get() failed: %s", tostring(unwrapped))
        end
    end
    trace("replaying %d target(s) with replayMode=%s, %d per frame", #targets, config.replayMode, config.chestsPerTick)

    -- "replayed", not "deposited": the job only proves the engine accepted the
    -- call, not that its own deposit logic moved anything. Report #1's companion
    -- symptom (deposits silently not happening) was invisible precisely because
    -- this used to claim success.
    startJob({
        authorisedBy = authorisedBy,
        asc = asc,
        comp = comp,
        ownerOffset = ownerOffset,
        originAddr = originAddr,
        handle = handle,
        origKey = origKey,
        targetData = targetDataArg,
        tag = tag,
        curKey = curKey,
        targets = targets,
        index = 1,
        replayed = 0,
        aborted = false,
    })
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

-- pTargetData (FGameplayAbilityTargetDataHandle, wrapping the game's
-- FR5TargetData_InteractionOption) is where the chosen interact option lives,
-- and it stays unreadable from Lua: not UPROPERTY-reflected, TArray access
-- patterns fail, and RegisterCustomProperty offset probes read back nil because
-- passed-by-value RPC params are not wired into UE4SS's property lookup the way
-- a live UObject reference is. A 2026-10-02 run also showed UE4SS handing the
-- RPC's other by-value params (handle, prediction key, ApplicationTag) back as
-- opaque UScriptStruct userdata - so their fields are unreadable too, and
-- SmartStorage's FPredictionKey.Current read cannot be working either.
--
-- Hence the identity gate upstream, which uses the interact option ability the
-- game constructs before the RPC arrives, and hence the origin approximation
-- below: nearest chest in interact range.
-- Debug-only extras: which ASC calls happen at all, plus the counter summary.
local function registerDebugDiagnostics()
    for _, path in ipairs(DEBUG_RPC_CANDIDATES) do
        pcall(function()
            RegisterHook(path, function() trace("FIRED %s", path) end)
        end)
    end
    startDiagnosticSummary()
    trace("extra RPC diagnostics armed")
end

if config.enabled then
    registerProbes()
    -- Armed unconditionally: this is the mod's interaction-identity signal, not a
    -- diagnostic. It costs one cached class-name lookup per interaction.
    pcall(function() registerInteractOptionCapture() end)
    if config.debug then registerDebugDiagnostics() end
    if probesRegistered then
        RegisterHook(
            "/Script/GameplayAbilities.AbilitySystemComponent:ServerSetReplicatedTargetData",
            function() end,
            function(context, pAbilityHandle, pOrigKey, pTargetData, pAppTag, pCurKey)
                count("hook-observed")
                if inMultipass then
                    count("own-replay")
                    return
                end
                local ok, err = pcall(function()
                    runMultipass(context:get(), pAbilityHandle, pOrigKey, pTargetData, pAppTag, pCurKey)
                end)
                if not ok then log("multipass error: %s", tostring(err)) end
            end
        )
    end
    log("v%s loaded - radius %.0fm, max attempts %d, %d/tick, replayMode %s, %s gate%s",
        VERSION, config.radiusMeters, config.maxAttempts, config.chestsPerTick,
        config.replayMode, config.failClosed and "fail-closed" or "permissive",
        config.debug and " (debug diagnostics armed)" or "")
else
    log("v%s loaded but disabled via config", VERSION)
end
