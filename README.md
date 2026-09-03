# PonyFlight

Replaces PPM/2's pegasus flight system with a more animated, momentum-based flight system. Requires PPM/2.

# Installation
Install from the workshop page or drop this whole folder into your /addons/ folder.

## Providers
(For external addons.)

Gamemodes can register a flight provider that determines a pony's flight eligibility plus vertical and horizontal flight speeds.

Register a provider:

```lua
PonyFlight.SetProvider("mygamemode", {
    CanFly            = function(ply) return ply:GetNWBool("can_fly", false) end,
    SpeedMult         = function(ply) return 1 end,
    VerticalSpeedMult = function(ply) return 1 end,
})
```

Each field is optional and falls back to the default behavior.
Since flight movement is predicted, you need to read the actual networked state rather than the server-only tables in your implemetation, otherwise it could cause rubber-banding.

| Field | Scales | Base |
| --- | --- | --- |
| `SpeedMult` | horizontal flight speed | `PonyFlight.SPEED` (650 hu/s) |
| `VerticalSpeedMult` | climb speed | `PonyFlight.CLIMB_SPEED` (420 hu/s) |

If CanFly changes mid-flight, call `PonyFlight.Recheck(ply)`.

## ConVars

| ConVar | Realm | Default | |
| --- | --- | --- | --- |
| `ponyflight_enterthirdperson` | client | `1` | Switch to third person while flying |
| `ponyflight_forcethirdperson` | server, replicated | `0` | Force third person while flying, and hold players in it |
| `ponyflight_enablegore` | server | `1` | Blood and gore on a fatal crash. `0` kills the pony and leaves them whole |

With Simple ThirdPerson installed we switch its view on rather than running our
own camera, so the player keeps the distance and smoothing they already tuned.
Either way we hold them in third person for the flight and put the setting back
on landing.

## Hooks

| Hook | Fired when |
| --- | --- |
| `PonyFlight_Changed(ply, flying, reason)` | a pony takes off or lands |
| `PonyFlight_ProviderChanged(name)` | a host registers or clears a provider |

## Credits

The crash gore is lifted from [RAMI'S Drugs [Consumables]](https://steamcommunity.com/sharedfiles/filedetails/?id=3728940551) because I thought it was cool
