# PonyFlight

Pegasus flight for PPM/2 ponies, built on the engine's own movement rather
than beside it.

## Why it exists

PPM/2 ships a flight controller (`ponyfly.moon`) that never actually moves
the player. Its `FinishMove` runs a hull trace and calls `SetPos`, adding raw
velocity to the origin with no frame scaling, so the "velocity" it carries is
units-per-tick. Two things follow:

- **Entity velocity is meaningless while flying.** Anything reading
  `GetVelocity` sees roughly nothing, which is why Falling Wind and Fly By
  Sounds both go quiet midair -- they are handed a number in the wrong unit,
  an order of magnitude below their thresholds. PPM/2 multiplies by 50 to
  convert back on landing, which is the same admission.
- **Collision is a single trace with an ad-hoc bounce**, so fast flight snags
  on corners instead of sliding along them.

PonyFlight writes velocity onto the movedata and lets default movement run.
`TryPlayerMove` gives real collision and sliding, and the velocity lands on
the player where every other addon can read it. The sound addons need no
patch at all.

PPM/2's own flight is removed outright, not merely disabled: `ppm2_sv_flight
0` guards only its `SetupMove` hook, while its `Move`, `FinishMove` and
`CalcMainActivity` hooks gate purely on the `ppm2_fly` networked bool. All
four are removed, in both realms, and the convar is set as well.

## Who may fly

PonyFlight does the flying. It does not decide who is allowed to, or how
fast -- that is balance, and balance belongs to the game it is installed in.

Out of the box it reads the PPM/2 race: pegasi and alicorns fly, at the same
speed. Some servers slow alicorns down, but that is one game's design
decision rather than a fact about flight, so it is not baked in here.

A host gamemode can take that over:

```lua
PonyFlight.SetProvider("mygamemode", {
    CanFly            = function(ply) return ply:GetNWBool("can_fly") end,
    SpeedMult         = function(ply) return 1 end,
    VerticalSpeedMult = function(ply) return 1 end,
})
```

Every field is optional and falls back to the PPM/2 default, so a host that
only wants to change *who* flies need not restate the speeds. Fields are
type-checked at registration rather than on call, because these run inside
movement and a provider that errors every frame would take player movement
down with it.

Registering replaces rather than stacks -- two addons both claiming to own
who may fly is a conflict worth noticing, so the second one wins and says so
on the console.

When eligibility changes underneath a pony in mid-air, call
`PonyFlight.Recheck(ply)` and they will be grounded if they no longer
qualify. PPM/2 race changes are handled already, so a standalone install
needs no wiring.

## Hooks

| Hook | Fired when |
| --- | --- |
| `PonyFlight_Changed(ply, flying, reason)` | a pony takes off or lands |
| `PonyFlight_ProviderChanged(name)` | a host registers or clears a provider |

## Diagnostics

```
ponyflight_watch            watch yourself
ponyflight_watch <name>     watch somepony else, for the client/server split
ponyflight_watch_stop
```

## Requirements

PPM/2. That is the only hard dependency; no gamemode is required.

## Tuning

The numbers in `sh_flight.lua` are placeholders meant to be tried, felt and
edited -- deliberately constants rather than convars, so they are not left as
a console surface. Speeds are hu/s and compare directly against land speed
(~200 walk, ~400 run).
