local Flight = PonyFlight

for _, path in ipairs(Flight.WINGBEATS) do
    resource.AddSingleFile("sound/" .. path)
end

-- TryPlayerMove kills the velocity component going into whatever you hit, so
-- a wall shows up as a one-tick speed drop. The delta is the impact strength;
-- ordinary flying never loses more than acceleration allows.
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

-- The ground jump is tap one, the airborne press is tap two. No air-toggle to
-- land: descending and touching down is the only way out.
hook.Add("KeyPress", "PonyFlight.Takeoff", function(ply, key)
    if key ~= IN_JUMP then return end
    if Flight.IsFlying(ply) then return end
    if not Flight.CanFly(ply) then return end

    local last = ply.ponyFlightLastJump or 0

    -- Discarding the ground jump made takeoff need a third tap.
    if not ply:OnGround() and CurTime() - last <= Flight.DOUBLE_TAP then
        ply.ponyFlightLastJump = 0
        Flight.Start(ply)
    else
        ply.ponyFlightLastJump = CurTime()
    end
end)

-- FinishMove, not Think: it runs once per processed move with the
-- post-collision velocity already resolved, which is what the impact check wants.
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
-- Hosts call this when their own answer to CanFly changes. The PPM2 hook below
-- covers the default provider.
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
