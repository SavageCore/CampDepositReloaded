# CampDepositReloaded

A from-scratch, open reimplementation of [Skiprhax's Camp Deposit](https://www.nexusmods.com/windrose/mods/445) for [Windrose](https://store.steampowered.com/app/3041230/Windrose/), as a [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod instead of a version-locked native DLL. The original appears unmaintained and hardcodes byte offsets for one exact game build, so it breaks on every update. This rewrite drives the same game logic through Unreal's reflection system instead, so it isn't tied to any specific build.

## What it does

Press Q (Deposit Similar) on one chest, and every other chest within range gets the same treatment - exactly as if you'd looked at each one and pressed Deposit Similar yourself.

It is **not** an auto-sorter: it doesn't choose categories or send items into empty chests. It only extends the game's own "move items whose type already exists in the target" logic to nearby chests.

## Features

- Extends vanilla Deposit Similar to every chest within a configurable radius
- Works in singleplayer, self-hosted co-op (Host Game/Listen server), and on a dedicated server
- **Server-side only** - like the original mod, nothing to install on clients if using on a dedicated server
- No new menu, no new hotkey - it rides the existing Deposit Similar action

## How it works

Deposit Similar reaches the server as a single call: `AbilitySystemComponent:ServerSetReplicatedTargetData`, replicated from the client as part of Windrose's Gameplay Ability System interact flow. The mod hooks that call _after_ it completes, so the player's own deposit always runs first and lands in the chest they actually meant.

The destination chest turns out to be resolved through the interact target component's owning actor, not through anything readable in the replicated payload itself (which is an opaque, game-specific struct with no reflected accessor). So for every other chest in range, the mod:

1. Temporarily points the origin chest's `InteractTargetComponent` owner at that chest
2. Re-fires the identical RPC call - the server re-resolves the destination through the (now lying) component and runs its own native deposit again
3. Restores the component afterward

The owner pointer's byte offset isn't a fixed constant in the mod - it's discovered at runtime by scanning `UActorComponent`'s memory for a pointer back to the chest, so an offset shift on a future game update degrades to "the mod logs a warning and does nothing" rather than silently corrupting memory.

The origin chest itself is approximated as the chest nearest the depositing player, since the replicated payload doesn't expose it directly - true whenever the player deposits at point-blank range, which vanilla Deposit Similar always requires anyway.

## Config

Settings live in `CampDepositReloaded.cfg.lua`, next to the installed `main.lua` (created on first edit, not tracked in git):

```lua
return {
    enabled = true,
    radiusMeters = 48.0,
    maxAttempts = 16,
    runtimeLogging = true,
    debug = false,
}
```

| Key              | Default | Meaning                                                           |
| ---------------- | ------- | ----------------------------------------------------------------- |
| `enabled`        | `true`  | Master on/off switch                                              |
| `radiusMeters`   | `48.0`  | Search radius for nearby chests                                   |
| `maxAttempts`    | `16`    | Cap on chests deposited into per Deposit Similar use              |
| `runtimeLogging` | `true`  | Log activity to `UE4SS.log`                                       |
| `debug`          | `false` | Verbose per-deposit tracing, for troubleshooting a silent failure |

## Requirements

- [UE4SS (experimental-latest)](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest)

## Install

Install wherever the game's **authoritative server logic** actually runs. Not needed on clients.

- **Dedicated server:** install into that server's own `R5/Binaries/Win64/`.
- **Singleplayer:** install into your normal game install (`R5/Binaries/Win64/`) - the single process is its own authority.
- **Host Game (listen server via invite code):** hosting spins up a _separate_ `WindroseServer-Win64-Shipping.exe` process from `R5/Builds/WindowsServer/R5/Binaries/Win64/` - a self-hosted dedicated server running alongside your normal client. **That** is where the deposit is actually authoritative, not your visible game client. Install UE4SS and this mod into `R5/Builds/WindowsServer/R5/Binaries/Win64/` too (same steps below, different directory), or Host Game deposits will silently do nothing, since the mod never sees them.

### 1. Install UE4SS

Extract the `dwmapi.dll` and `ue4ss` folder to the `R5\Binaries\Win64` directory.

> **Linux tip:** Set your launch option to `WINEDLLOVERRIDES="dwmapi=n,b" %command%` to load UE4SS.

### 2. Configure UE4SS

Open `UE4SS-settings.ini` and update the `[EngineVersionOverride]` section:

```ini
[EngineVersionOverride]
MajorVersion = 5
MinorVersion = 6
```

### 3. Install the mod

Download the [latest release](https://github.com/SavageCore/CampDepositReloaded/releases/latest) and extract it to `R5/Binaries/Win64/ue4ss/Mods/`.

You should end up with:

```
ue4ss/Mods/CampDepositReloaded/
├── enabled.txt
└── Scripts/
    └── main.lua
```

## Development

### Prerequisites

- `make`
- A local Windrose installation (Linux/Steam or override path)

### Build & Install

Symlink the mod directly into your game's Mods folder:

```bash
make install
```

The default install path is:

```
~/.local/share/Steam/steamapps/common/Windrose/R5/Binaries/Win64/ue4ss/Mods
```

Override it for a custom location:

```bash
make install INSTALL_DIR=/path/to/ue4ss/Mods
```

To test Host Game locally, also install into the game's bundled server build (see [Install](#install)):

```bash
make install INSTALL_DIR="$HOME/.local/share/Steam/steamapps/common/Windrose/R5/Builds/WindowsServer/R5/Binaries/Win64/ue4ss/Mods"
```

Build only (output goes to `build/CampDepositReloaded/`):

```bash
make build
```

Linting is [luacheck](https://github.com/lunarmodules/luacheck), run in CI and as a [lefthook](https://lefthook.dev) pre-commit hook:

```sh
lefthook install
```
