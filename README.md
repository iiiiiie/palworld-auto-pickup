# Palworld Auto Pickup

English | [中文](README.zh-CN.md)

Server-side UE4SS Lua mod for Palworld Steam. When a Pal is killed, the Pal's
native death drops are picked up by the killer player automatically.

## Behavior

- Works only for Pal death drops created by Palworld's native death-drop flow.
- Supports player kills, mounted player kills, active summoned Pal kills, and
  mounted Pal kills when the attacker can be resolved back to a player.
- Uses Palworld's native pickup request path, so inventory limits and server
  synchronization remain handled by the game.
- Fails closed. If the drop cannot be tied to a validated Pal death context, it
  is left in the world.
- Does not auto-pick mining, logging, harvesting, treasure, player-dropped
  items, or humanoid NPC drops.

## Install

Install UE4SS for the target Palworld Steam build, then place this folder at:

```text
Pal/Binaries/Win64/ue4ss/Mods/AutomaticPickup
```

Expected layout:

```text
AutomaticPickup/
  enabled.txt
  Scripts/
    config.lua
    main.lua
```

For multiplayer dedicated servers, install UE4SS and this mod on the server.
Clients do not need to install the mod for server-authoritative pickup.

Use a UE4SS build known to work with the current Palworld Steam version. This
project does not pin an old generic UE4SS release.

## Configuration

Edit `AutomaticPickup/Scripts/config.lua`.

- `ENABLED`: Turns the mod on or off.
- `STRICT_SOURCE_BINDING`: Keeps pickup limited to validated Pal death drops.
  Leave this enabled for normal use.
- `DEBUG_SOURCE_BINDING`: Logs death context, binding, and ignore reasons.
- `ASYNC_BIND_WINDOW_SECONDS`: Short window for Pal death drops created after
  the native death hook returns.
- `ASYNC_BIND_RADIUS`: Location fallback radius used only inside an already
  validated Pal death context.
- `PICKUP_DELAY_MS`: Delay before requesting native pickup after the drop
  becomes interactable.

## Logs

UE4SS writes mod logs to:

```text
Pal/Binaries/Win64/ue4ss/UE4SS.log
```

Enable `DEBUG_SOURCE_BINDING` when validating a new Palworld or UE4SS build.
Look for messages such as `opened death context`, `bound drop model`, and
`requested pickup for player id`.

## Compatibility Notes

The mod intentionally does not copy or reimplement Palworld drop tables. Drop
rates, quantities, world settings, inventory limits, and pickup permissions stay
native to the game.

If Palworld changes the death-drop or map-object lifecycle, this mod may need a
small hook update. The strict fallback behavior is intentionally conservative to
avoid collecting unrelated world drops.
