# Verification runbook

Reports #1 (server lag), #2 (doors and windows closing again) and #3 (a deposit
silently skipped after looting) have been addressed; this is how to check the
result, and how to re-run the discovery if a game update changes the picture.

The mod's behaviour rests on measurements taken on 2026-10-02, all of which are
worth re-confirming after any game update because each one names something the
game could rename:

1. `ServerSetReplicatedTargetData` fires for deposits, doors, chest opens and
   looting - it is the generic targeted-interact path, not a deposit path.
2. The interact option ability constructed just before each RPC names the
   action: `GA_InteractOption_DepositSimilar_C`, `R5Ability_InteractOption_ToggleDoor`,
   `GA_InteractWithObject_ExternalInvetory_C`.
3. The option's outer object is the player's `BP_R5PlayerState_C`, the same object
   that owns the ASC carrying the RPC.
4. The RPC's by-value params come back as opaque `UScriptStruct` userdata.
5. `R5Ability_InteractOption_Base:GetTargetActor` is hookable but returns invalid.
6. The replay only works with the target data unwrapped (`replayMode = "unwrapped"`).
7. Camp scoping works: `R5BuildingCenterStorageComponent.BuildingGraphIds` groups a
   camp's chests.

## 1. Install

```bash
make install
```

`make install` also links `build/CampDepositReloaded/Scripts/CampDepositReloaded.cfg.lua`
into the installed mod directory when it exists. This matters more than it looks:
`main.lua` resolves its config next to *itself*, the installed copy is a symlink
into `build/`, and without the link every session silently ran on the hardcoded
defaults - which is how two rounds of testing produced no `[debug]` output at all.

Config for a diagnostic run:

```lua
return {
    enabled = true,
    debug = true,
    runtimeLogging = true,
    replayMode = "unwrapped",
}
```

`debug = true` arms the diagnostics, and the load line then ends with
`(debug diagnostics armed)` - if you do not see that suffix, the config was not
read. With `debug` off the mod behaves like the released 0.1.0 plus the
`interactRangeMeters` guard.

For a dedicated server, write the same file into that build's Mods folder
instead - see Install in the README.

## 2. Test sequence

Prepare first: put the same item (say wood) in **two or three** chests. Deposit
Similar only moves items whose type the target chest already holds, so a fan-out
into an empty chest is a no-op by design and tells us nothing. Keep spare wood in
your inventory, stand next to one of the loaded chests, and have a door within a
few metres.

The three actions that decide the design, then stop:

| # | Action | Expected in the log |
| - | ------ | ------------------ |
| 1 | Press Q (Deposit Similar) at the loaded chest, carrying spare wood | `interact option: class=GA_InteractOption_DepositSimilar_C`, then `replayed deposit into N of M nearby chest(s)` |
| 2 | Open and close a door next to the chests | `class=R5Ability_InteractOption_ToggleDoor` and **nothing else** - no replay, no chest scan |
| 3 | Open a chest without depositing, then take an item out of it | `class=GA_InteractWithObject_ExternalInvetory_C` and nothing else |
| 4 | Immediately press Q again, with no pause | A replay happens: the cooldown is stamped by fan-outs, not by blocked interactions |

Then close the game. Optional extras if you have time: two camps within one radius
(to confirm only the origin camp is touched), and 100+ chests in one camp (to feel
the frame pacing).

## 3b. Host Game / dedicated server

Host Game is the real server path: it spawns `WindroseServer-Win64-Shipping.exe` as
its own process, with no local player, which is the same code a headless dedicated
server runs. Install the mod in *that* build's Mods folder
(`R5/Builds/WindowsServer/R5/Binaries/Win64/ue4ss/Mods`), host a game, then repeat
steps 1-4. The log to read is that build's `ue4SS.log`, not the client's.

Two things worth knowing about this setup:

- The host's **client** process also has the mod installed and will log nothing,
  because a client never executes the target-data RPC. Authoritative deposits
  happen only in the server process, so there is no double deposit and no
  client-side prediction to desync.
- A single player on a dedicated server does **not** exercise the per-player
  keying of the identity gate. Two players joining the same game, each depositing,
  is the test that does.

Every runtime fan-out line ends with the option class that authorised it:

```
replayed deposit into 2 of 2 nearby chest(s) [GA_InteractOption_DepositSimilar_C]
```

A fan-out without that suffix means `failClosed` was turned off; any other class
name means something other than Deposit Similar got through.

## 3. Collect the log

`UE4SS.log` sits next to `UE4SS.dll`, i.e.
`R5/Binaries/Win64/ue4ss/UE4SS.log` (or the server build's equivalent). You do not
need to paste anything - just say when you have quit the game and the log will be
read directly. What we are looking for is in the `[CampDepositReloaded]` lines:
`appTag=`, `predictionKey=`, `interact option constructed:` and `GetTargetActor`
lines, plus the `summary:` counters.

## 4. Replay mode

`replayMode = "unwrapped"` is the working mode: released v0.1.0 and SmartStorage
both pass `pTargetData:get()` to the replayed RPC. `"wrapper"` (the raw
UE4SS `RemoteUnrealParam`) is retained only so the older SIGSEGV hypothesis can be
re-tested deliberately - but note that it does not merely crash, it is rejected
by the engine on every call, which is why the unreleased wrapper-passthrough build
reported `replayed deposit into 0 nearby chest(s)` and fanned out nothing at all.

## 5. Reading the results

| Observation | What it means |
| ----------- | ------------- |
| `replayed deposit into N` with N > 0 on a door or a chest open | The fan-out replays non-deposits: doors toggle once per chest. This is report #2. Already reproduced. |
| `no chest accepted a replay of N target(s)` | The engine refused every replay. The reason is on the preceding `replay rejected` line. |
| `appTag=` differs between the deposit and the door | ApplicationTag is the gate. Cheapest possible fix, no new hooks. |
| `predictionKey=` readable and unique per press | Already used for one-fan-out-per-activation; keeps working as the dedupe. |
| `interact option constructed:` with `GA_InteractOption_DepositSimilar_C` per interaction | Class name is the gate, and `GetTargetActor` gives the exact origin chest. |
| `interact option constructed:` once per player, not per interaction | Option instances are reused; identity has to come from the RPC params. |
| `GetTargetActor post` lines present | The option can be called directly for the origin chest. |
| `GetTargetActor pre` never appears | The option's getters are C++-only, so they cannot be hooked, though they may still be callable. |
| `interaction options: ... depositSimilar=true` | Confirms Deposit Similar is a real option object in the option list. |
| `node=... campChests=N` with N > 1 | Camp-scoped targeting works on this build (already in use by default). |
| `skip:fanout-busy` climbing | Interactions are colliding with an in-flight fan-out; check `chestsPerTick`. |
| `abandoning a fan-out that stalled` | A frame-slice callback was dropped; the watchdog reaped it. |
| No `[CampDepositReloaded]` lines at all | The mod did not load in that process - check the install path. |
| Load line without `(debug diagnostics armed)` | The config was not read - check that `make install` linked it. |

## Caveat

Singleplayer runs client and server in one process, so client-side signals
(option construction, UI option lists) show up even if a dedicated server would
not produce them. Treat anything driven by `NotifyOnNewObject` or the option
model as *provisional* until confirmed on a dedicated server or a Host Game
listen server.
