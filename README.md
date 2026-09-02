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

## Hooks

| Hook | Fired when |
| --- | --- |
| `PonyFlight_Changed(ply, flying, reason)` | a pony takes off or lands |
| `PonyFlight_ProviderChanged(name)` | a host registers or clears a provider |
