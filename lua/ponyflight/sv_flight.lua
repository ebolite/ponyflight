local Flight = PonyFlight

for _, path in ipairs(Flight.WINGBEATS) do
    resource.AddSingleFile("sound/" .. path)
end

-- A wall takes the horizontal speed and a landing takes the vertical, so we
-- watch the horizontal drop to tell a crash from touching down.
Flight.IMPACT_FLOOR = 320   -- we don't damage below this
Flight.GIB_SPEED = 900      -- explode

local IMPACT_DEBUG = CreateConVar("ponyflight_debug_impact", "0", FCVAR_NOTIFY,
    "Print what each flight lost when it ended, to find why a crash did not register")

local function impactDamage(speed)
    -- Damage is quadratic so low speed collisions don't destroy you
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

    -- First flap starts immediately
    setFlapping(ply, true)

    -- Gravity remains active
    -- Flight lift acts against it
    ply:SetGravity(1)
    ply.ponyFlightLastSpeed = ply:GetVelocity():Length()
    ply.ponyFlightLastHorizontal = Vector(ply:GetVelocity().x, ply:GetVelocity().y, 0):Length()

    hook.Run("PonyFlight_Changed", ply, true)
end

function Flight.Stop(ply, reason)
    if not IsValid(ply) then return end
    if not ply:GetNWBool(Flight.NW_VAR, false) then return end

    ply:SetNWBool(Flight.NW_VAR, false)
    setFlapping(ply, false)
    ply:SetGravity(1)
    ply.ponyFlightLastSpeed = nil
    ply.ponyFlightLastHorizontal = nil
    ply.ponyFlightLastDescent = nil

    hook.Run("PonyFlight_Changed", ply, false, reason)
end

hook.Add("KeyPress", "PonyFlight.Takeoff", function(ply, key)
    if key ~= IN_JUMP then return end
    if Flight.IsFlying(ply) then return end
    if not Flight.CanFly(ply) then return end

    -- One press, as long as we are already airborne. Jumping still costs the
    -- press that leaves the ground, so a standing takeoff is jump then fly
    if not ply:OnGround() then
        Flight.Start(ply)
    end
end)

-- FinishMove runs once per processed move, so we hook there instead of Think
hook.Add("FinishMove", "PonyFlight.Upkeep", function(ply, mv)
    if not Flight.IsFlying(ply) then return end

    if not Flight.CanFly(ply) then
        Flight.Stop(ply, "cannot_fly")
        return
    end

    local velocity = mv:GetVelocity()
    local speed = velocity:Length()
    local horizontal = Vector(velocity.x, velocity.y, 0):Length()

    local previous = ply.ponyFlightLastSpeed or speed
    local previousHorizontal = ply.ponyFlightLastHorizontal or horizontal
    ply.ponyFlightLastSpeed = speed
    ply.ponyFlightLastHorizontal = horizontal

    -- Horizontal only. Gravity owns the descent now, so a fall arrives fast
    -- enough that a total-speed drop would read every landing as a crash.
    local lost = previousHorizontal - horizontal

    -- Descent is only measured for the readout; nothing decides on it yet
    local descent = math.max(-velocity.z, 0)
    local previousDescent = ply.ponyFlightLastDescent or descent
    ply.ponyFlightLastDescent = descent

    if IMPACT_DEBUG:GetBool() and (lost > 60 or previousDescent - descent > 60) then
        MsgN(string.format(
            "[ponyflight] %s  total %.0f  horizontal lost %.0f  descent lost %.0f  floor %d%s",
            ply:Nick(), previous, lost, previousDescent - descent, Flight.IMPACT_FLOOR,
            lost >= Flight.IMPACT_FLOOR and "  <- CRASH" or ""))
    end

    if lost >= Flight.IMPACT_FLOOR then
        local crashSpeed = previous

        Flight.Stop(ply, "impact")

        -- Next frame, not here. Damage dealt from inside a movement hook does
        -- not reliably reach the player, and the crash was being detected and
        -- the flight ended while the pony walked away unhurt.
        timer.Simple(0, function()
            if not IsValid(ply) or not ply:Alive() then return end

            if crashSpeed >= Flight.GIB_SPEED then
                gib(ply)
                return
            end

            local dealt = impactDamage(crashSpeed)

            local damage = DamageInfo()
            damage:SetDamage(dealt)
            damage:SetDamageType(DMG_CRUSH)
            damage:SetAttacker(ply)

            -- The world, not the pony. A gamemode reading the inflictor to
            -- classify a swing sees a player holding a weapon otherwise, and
            -- PonyRP's melee pipeline scaled the crash by the tribe multiplier.
            damage:SetInflictor(game.GetWorld())

            local healthBefore, armorBefore = ply:Health(), ply:Armor()
            ply:TakeDamageInfo(damage)

            if IMPACT_DEBUG:GetBool() then
                MsgN(string.format(
                    "[ponyflight] %s  dealt %.0f  health %d -> %d  armor %d -> %d  god %s",
                    ply:Nick(), dealt, healthBefore, ply:Health(),
                    armorBefore, ply:Armor(), tostring(ply:HasGodMode())))
            end
        end)

        return
    end

    if ply:OnGround() then
        if IMPACT_DEBUG:GetBool() then
            MsgN(string.format("[ponyflight] %s  landed  total %.0f  horizontal lost %.0f",
                ply:Nick(), previous, lost))
        end

        Flight.Stop(ply, "landed")
        return
    end

    setFlapping(ply, mv:KeyDown(IN_JUMP))
end)

-- Everything else that should ground a pony
hook.Add("PlayerDeath", "PonyFlight.Death", function(ply) Flight.Stop(ply, "died") end)
hook.Add("PlayerSpawn", "PonyFlight.Spawn", function(ply) Flight.Stop(ply, "spawned") end)
hook.Add("PlayerEnteredVehicle", "PonyFlight.Vehicle", function(ply) Flight.Stop(ply, "vehicle") end)
hook.Add("PlayerNoClip", "PonyFlight.NoClip", function(ply) Flight.Stop(ply, "noclip") end)
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

-- Does damage reach this pony at all, outside anything we do? If this prints
-- no change either, the crash path is not the problem.
concommand.Add("ponyflight_test_damage", function(ply)
    if not IsValid(ply) then return end

    local health, armor = ply:Health(), ply:Armor()

    local damage = DamageInfo()
    damage:SetDamage(25)
    damage:SetDamageType(DMG_CRUSH)
    damage:SetAttacker(ply)
    damage:SetInflictor(game.GetWorld())
    ply:TakeDamageInfo(damage)

    local viaTakeDamage = ply:Health()
    ply:TakeDamage(25, ply, game.GetWorld())

    MsgN(string.format(
        "[ponyflight] test  health %d -> %d (TakeDamageInfo) -> %d (TakeDamage)" ..
        "  armor %d -> %d  god %s  movetype %d",
        health, viaTakeDamage, ply:Health(), armor, ply:Armor(),
        tostring(ply:HasGodMode()), ply:GetMoveType()))
end, nil, "Apply 25 crush damage to yourself two ways, to see whether damage lands at all")
