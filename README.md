# PonyFlight

Replaces PPM/2's pegasus flight system with a more animated, momentum-based flight system. Requires PPM/2.

## Controlling flight

PonyFlight does the flying; a host gamemode decides who flies and how fast.
Register a provider:

```lua
PonyFlight.SetProvider("mygamemode", {
    CanFly            = function(ply) return ply:GetNWBool("can_fly", false) end,
    SpeedMult         = function(ply) return 1 end,
    VerticalSpeedMult = function(ply) return 1 end,
})
```

Every field is optional and falls back to the default, which flies PPM/2
pegasi and alicorns at equal speed. Fields are type-checked at registration,
not on call. Registering replaces rather than stacks: one addon owns flight,
and the second to register wins and says so on the console.

### What the multipliers scale

| Returned by | Scales | Base |
| --- | --- | --- |
| `SpeedMult` | horizontal cruise | `Flight.SPEED` (650 hu/s) |
| `VerticalSpeedMult` | climb **and** dive together | `Flight.CLIMB_SPEED` (420), `Flight.DIVE_SPEED` (780) |

Both are read every movement frame, per player. `1` leaves the base alone.
There is no separate climb and dive knob -- halving one halves the other.

Neither multiplier touches passive sink (`Flight.SINK`), glide decay
(`Flight.GLIDE_DRAG`) or acceleration (`Flight.ACCEL`). A slowed pony still
sinks at the same rate and still reaches its lower cruise in about the same
time, so slowing a flier makes holding altitude disproportionately expensive.
That is a real effect worth tuning around, not a rounding error.

### Answer the same in both realms

Flight movement is predicted -- the `Move` hook runs on the client and on the
server. A provider that answers differently in the two realms rubber-bands.
Read networked or otherwise shared state, never a server-only table.

### Global feel

`Flight.SPEED`, `CLIMB_SPEED`, `DIVE_SPEED`, `ACCEL`, `GLIDE_DRAG` and
`SINK` are plain fields on the `PonyFlight` table. Overwriting them changes
flight for everypony rather than per player, and must be done in both realms
for the same reason as above.

### When eligibility changes

Call `PonyFlight.Recheck(ply)` when your own answer to `CanFly` changes and a
pony who no longer qualifies is grounded. PPM/2 race changes are covered
already, so a standalone install needs no wiring.

## Hooks

| Hook | Fired when |
| --- | --- |
| `PonyFlight_Changed(ply, flying, reason)` | a pony takes off or lands |
| `PonyFlight_ProviderChanged(name)` | a host registers or clears a provider |
