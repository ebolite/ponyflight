--[[
PonyFlight -- server authority.

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

local Flight = PonyFlight

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

local function setFlapping(ply, flapping)
    if ply:GetNWBool(Flight.FLAP_NW_VAR, false) == flapping and
            ply:GetNW2Bool(Flight.PPM2_NW_VAR, false) == flapping then
        return
    end

    ply:SetNWBool(Flight.FLAP_NW_VAR, flapping)
    ply:SetNW2Bool(Flight.PPM2_NW_VAR, flapping)
end

function Flight.Start(ply)
    if not Flight.CanFly(ply) or Flight.IsFlying(ply) then return end

    ply:SetNWBool(Flight.NW_VAR, true)

    -- Takeoff happens on a Space press, so its first flap starts immediately.
    -- Subsequent FinishMove calls keep this paired to the held key.
    setFlapping(ply, true)

    -- Gravity remains active: holding Space supplies lift, while releasing it
    -- lets the pony lose altitude naturally.
    ply:SetGravity(1)
    ply.ponyFlightLastSpeed = ply:GetVelocity():Length()

    hook.Run("PonyFlight_Changed", ply, true)
end

function Flight.Stop(ply, reason)
    if not IsValid(ply) then return end
    if not ply:GetNWBool(Flight.NW_VAR, false) then return end

    ply:SetNWBool(Flight.NW_VAR, false)
    setFlapping(ply, false)
    ply:SetGravity(1)
    ply.ponyFlightLastSpeed = nil

    hook.Run("PonyFlight_Changed", ply, false, reason)
end

--[[
Double-tap Space to take off: the ground jump is tap one and the airborne
press is tap two. A standing start therefore still costs a jump, which is
the only brake on takeoff until playtest says whether it needs a real one.

There is deliberately no air-toggle to land: descending and touching down is
the only way out. That makes landing something you fly rather than a key you
press, and it keeps Space unambiguous in the air, where it is the climb.
]]
hook.Add("KeyPress", "PonyFlight.Takeoff", function(ply, key)
    if key ~= IN_JUMP then return end
    if Flight.IsFlying(ply) then return end
    if not Flight.CanFly(ply) then return end

    local last = ply.ponyFlightLastJump or 0

    -- The ordinary ground jump is tap one. Flight may only begin once the
    -- pony is airborne, but throwing that first press away made takeoff need
    -- a third tap. KeyPress fires at the start of the second press, so keeping
    -- Space held after it also feeds lift to the Move hook immediately.
    if not ply:OnGround() and CurTime() - last <= Flight.DOUBLE_TAP then
        ply.ponyFlightLastJump = 0
        Flight.Start(ply)
    else
        ply.ponyFlightLastJump = CurTime()
    end
end)

--[[
Per-move upkeep: impact detection and flap-input replication.

FinishMove rather than Think because it runs once per processed move with
the post-collision velocity already resolved, which is exactly the number
the impact check wants.
]]
hook.Add("FinishMove", "PonyFlight.Upkeep", function(ply, mv)
    if not Flight.IsFlying(ply) then return end

    if not Flight.CanFly(ply) then
        Flight.Stop(ply, "cannot_fly")
        return
    end

    local velocity = mv:GetVelocity()
    local speed = velocity:Length()
    local previous = ply.ponyFlightLastSpeed or speed
    ply.ponyFlightLastSpeed = speed

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

    -- Clients play the sound on their locally rendered gesture boundaries,
    -- so prediction and network delay cannot separate audio from animation.
    setFlapping(ply, mv:KeyDown(IN_JUMP))
end)

-- Everything else that should ground a pony.
hook.Add("PlayerDeath", "PonyFlight.Death", function(ply) Flight.Stop(ply, "died") end)
hook.Add("PlayerSpawn", "PonyFlight.Spawn", function(ply) Flight.Stop(ply, "spawned") end)
hook.Add("PlayerEnteredVehicle", "PonyFlight.Vehicle", function(ply) Flight.Stop(ply, "vehicle") end)
--[[
Eligibility can stop being true underneath a pony in mid-air -- a race
change, a job change, whatever the host gates on. PonyFlight cannot know
what those events are, so it exposes the recheck and the host calls it.

The PPM/2 hook below covers the default provider, so a standalone install
still grounds a pegasus who becomes an earth pony without anypony wiring
anything up.
]]
function Flight.Recheck(ply)
    if not IsValid(ply) then return end
    if not ply:GetNWBool(Flight.NW_VAR, false) then return end
    if Flight.CanFly(ply) then return end

    Flight.Stop(ply, "ineligible")
end

function Flight.RecheckAll()
    for _, ply in ipairs(player.GetAll()) do Flight.Recheck(ply) end
end

hook.Add("PPM2_PonyDataChanges", "PonyFlight.RecheckOnPonyData", function(ent)
    if IsValid(ent) and ent:IsPlayer() then Flight.Recheck(ent) end
end)

-- A new provider can disagree with the old one about who is airborne.
hook.Add("PonyFlight_ProviderChanged", "PonyFlight.RecheckOnProvider", function()
    Flight.RecheckAll()
end)
