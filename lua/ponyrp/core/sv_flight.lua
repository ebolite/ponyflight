--[[
PonyRP pegasus flight -- server authority.

Owns who is flying and why they stopped. Activation is double-tapped Space
in midair, per design; there is deliberately no takeoff windup yet, since
whether flight even needs one is a question for playtest rather than for
this file. When that answer arrives it belongs here, between the double-tap
and Flight.Start.

Collisions stay lethal. A pegasus who flies into a wall at speed should hurt
themselves, and at real speed should come apart. This is the one place the
spec's 75 HP works in our favour: it makes the number small enough that the
damage curve does not need to be vicious to be funny.
]]

local Flight = PonyRP.Flight

-- Clients need the wingbeats even if they never subscribed to the addon.
for _, path in ipairs(Flight.WINGBEATS) do
    resource.AddSingleFile("sound/" .. path)
end

--[[
Impact damage.

Detected by watching how much speed vanished in a single tick. The engine's
TryPlayerMove kills the component of velocity going into whatever you hit,
so a wall at 700 shows up as a ~700 drop in one tick, while ordinary flying
never loses more than acceleration allows. That makes the delta itself the
impact strength, with no trace of our own.
]]
Flight.IMPACT_FLOOR = 320   -- below this it is flying, not crashing
Flight.GIB_SPEED = 900      -- above this you do not land, you arrive

local function impactDamage(speed)
    -- Quadratic so gentle bumps are survivable and real speed is not.
    -- 400 -> ~6, 600 -> ~25, 800 -> ~57, 900+ -> gib.
    local over = (speed - Flight.IMPACT_FLOOR) / 100
    return math.Clamp(over * over * 4, 1, 200)
end

local function gib(ply)
    local pos = ply:WorldSpaceCenter()

    local effect = EffectData()
    effect:SetOrigin(pos)
    effect:SetNormal(VectorRand():GetNormalized())
    effect:SetMagnitude(6)
    effect:SetScale(4)
    effect:SetFlags(3)
    util.Effect("bloodspray", effect)
    util.Decal("Blood", pos, pos - Vector(0, 0, 96))

    ply:EmitSound("physics/flesh/flesh_bloody_break.wav", 100, math.random(95, 105))
    ply:Kill()
end

function Flight.Start(ply)
    if not Flight.CanFly(ply) or Flight.IsFlying(ply) then return end

    ply:SetNWBool(Flight.NW_VAR, true)

    -- PPM2's pose and spread wings key off this. Its movement hooks are
    -- gone (sh_flight.lua), so the bool is now purely cosmetic.
    ply:SetNW2Bool(Flight.PPM2_NW_VAR, true)

    -- The engine still applies gravity during its own move; zero it rather
    -- than fighting it every tick in the Move hook.
    ply:SetGravity(0)
    ply.ponyrpFlightLastSpeed = ply:GetVelocity():Length()
    ply.ponyrpFlightNextBeat = 0

    hook.Run("PonyRP_FlightChanged", ply, true)
end

function Flight.Stop(ply, reason)
    if not IsValid(ply) then return end
    if not ply:GetNWBool(Flight.NW_VAR, false) then return end

    ply:SetNWBool(Flight.NW_VAR, false)
    ply:SetNW2Bool(Flight.PPM2_NW_VAR, false)
    ply:SetGravity(1)
    ply.ponyrpFlightLastSpeed = nil

    hook.Run("PonyRP_FlightChanged", ply, false, reason)
end

--[[
Double-tapped Space, midair, to take off. Requiring midair means a standing
start already costs a jump, which is the only brake on takeoff until playtest
says whether it needs a real one.

There is deliberately no air-toggle to land: descending and touching down is
the only way out. That makes landing something you fly rather than a key you
press, and it keeps Space unambiguous in the air, where it is the climb.
]]
hook.Add("KeyPress", "PonyRP.Flight.Takeoff", function(ply, key)
    if key ~= IN_JUMP then return end
    if Flight.IsFlying(ply) then return end
    if ply:OnGround() or not Flight.CanFly(ply) then return end

    local last = ply.ponyrpFlightLastJump or 0

    if CurTime() - last <= Flight.DOUBLE_TAP then
        ply.ponyrpFlightLastJump = 0
        Flight.Start(ply)
    else
        ply.ponyrpFlightLastJump = CurTime()
    end
end)

--[[
Per-move upkeep: impact detection and the wingbeat rhythm.

FinishMove rather than Think because it runs once per processed move with
the post-collision velocity already resolved, which is exactly the number
the impact check wants.
]]
hook.Add("FinishMove", "PonyRP.Flight.Upkeep", function(ply, mv)
    if not Flight.IsFlying(ply) then return end

    if not Flight.CanFly(ply) then
        Flight.Stop(ply, "cannot_fly")
        return
    end

    local velocity = mv:GetVelocity()
    local speed = velocity:Length()
    local previous = ply.ponyrpFlightLastSpeed or speed
    ply.ponyrpFlightLastSpeed = speed

    local lost = previous - speed

    if lost >= Flight.IMPACT_FLOOR then
        if previous >= Flight.GIB_SPEED then
            gib(ply)
        else
            local damage = DamageInfo()
            damage:SetDamage(impactDamage(previous))
            damage:SetDamageType(DMG_CRUSH)
            damage:SetAttacker(ply)
            damage:SetInflictor(ply)
            ply:TakeDamageInfo(damage)
        end

        Flight.Stop(ply, "impact")
        return
    end

    -- Landing ends flight. Descending with Ctrl until you touch down is the
    -- intended way to stop, so there is no separate land command.
    if ply:OnGround() then
        Flight.Stop(ply, "landed")
        return
    end

    -- Wingbeat, on a constant cadence.
    --
    -- It used to scale with speed, and that sounded wrong for a real reason:
    -- PPM2's wings in flight are a bodygroup swap, not an animation, so the
    -- wingbeat you can see has no speed for the audio to track. Audio that
    -- sped up against wings that held still read as two unrelated things.
    -- A fixed cadence matches what is actually on screen; the jitter and the
    -- five variations keep it off a metronome.
    if CurTime() >= (ply.ponyrpFlightNextBeat or 0) then
        ply:EmitSound(
            Flight.WINGBEATS[math.random(#Flight.WINGBEATS)],
            70,
            math.random(94, 106),
            Flight.BEAT_VOLUME,
            CHAN_BODY)

        ply.ponyrpFlightNextBeat = CurTime() + Flight.BEAT_INTERVAL * math.Rand(0.94, 1.06)
    end
end)

-- Everything else that should ground a pony.
hook.Add("PlayerDeath", "PonyRP.Flight.Death", function(ply) Flight.Stop(ply, "died") end)
hook.Add("PlayerSpawn", "PonyRP.Flight.Spawn", function(ply) Flight.Stop(ply, "spawned") end)
hook.Add("PlayerEnteredVehicle", "PonyRP.Flight.Vehicle", function(ply) Flight.Stop(ply, "vehicle") end)
hook.Add("PonyRP_RaceChanged", "PonyRP.Flight.RaceChanged", function(ply)
    if not Flight.CanFly(ply) then Flight.Stop(ply, "race_changed") end
end)
