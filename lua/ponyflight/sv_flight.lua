local Flight = PonyFlight

for _, path in ipairs(Flight.WINGBEATS) do
    resource.AddSingleFile("sound/" .. path)
end

-- A wall takes the horizontal speed and a landing takes the vertical, so we
-- watch the horizontal drop to tell a crash from touching down.
Flight.IMPACT_FLOOR = 250   -- we don't damage below this
Flight.GIB_SPEED = 600      -- explode, well under the 650 cruise
Flight.IMPACT_LETHAL = 75   -- damage at GIB_SPEED, which is a pegasus entire

-- What Source already plays when a ragdoll hits the world hard. The engine
-- gives players no pain sound of their own in multiplayer, whatever damage
-- type it is handed, so the crash has to make its own noise.
Flight.IMPACT_SOUNDS = {
    "physics/body/body_medium_impact_hard1.wav",
    "physics/body/body_medium_impact_hard2.wav",
    "physics/body/body_medium_impact_hard3.wav",
    "physics/body/body_medium_impact_hard4.wav",
    "physics/body/body_medium_impact_hard5.wav",
    "physics/body/body_medium_impact_hard6.wav",
}

-- How bad the crash was, 0 at the floor and 1 at the gib speed. The damage and
-- the sound both read it, so a scrape sounds like one.
local function crashProgress(speed)
    local range = Flight.GIB_SPEED - Flight.IMPACT_FLOOR
    return math.Clamp((speed - Flight.IMPACT_FLOOR) / range, 0, 1)
end

-- Quadratic, so a scrape stays cheap while the top of the range does not.
local function impactDamage(speed)
    local progress = crashProgress(speed)
    return math.Clamp(progress * progress * Flight.IMPACT_LETHAL, 1, 200)
end

local function impactSound(ply, speed)
    local progress = crashProgress(speed)

    ply:EmitSound(
        Flight.IMPACT_SOUNDS[math.random(#Flight.IMPACT_SOUNDS)],
        75,
        math.random(95, 105) - progress * 15,   -- heavier lands lower
        0.55 + progress * 0.45,
        CHAN_BODY)
end

-- Lifted from RAMI'S Drugs [Consumables] (workshop 3728940551), whose expired
-- pre-workout does this to anypony who hits a wall at speed. Two changes: the
-- origin is the pony's centre rather than 45 units up, since a pony is shorter
-- than the player it was written for, and the damage type is not DMG_CRUSH --
-- DPP2's antipropkill zeroes that for players and strips the flags with it.
-- Server side rather than a client preference: the pieces and the decals are
-- entities everypony sees, so there is no half of this a single player can
-- turn off for themselves.
local ENABLE_GORE = CreateConVar("ponyflight_enablegore", "1",
    bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
    "Blood and gore on a fatal crash. 0 kills the pony and leaves them whole.")

-- A piece has to be moving to leave anything, and only marks a few times, so
-- ten of them settling in a corner cannot bury the map in decals.
local GIB_MARK_SPEED = 80
local GIB_MARK_LIMIT = 3

-- Bounces are reported from the physics thread, where making things is not
-- allowed, so the mark waits for the next frame.
local function markOnBounce(piece, data)
    if piece.PonyFlightMarks >= GIB_MARK_LIMIT then return end
    if data.Speed < GIB_MARK_SPEED then return end

    local heading = data.OurOldVelocity
    if not heading or heading:LengthSqr() < 1 then return end

    piece.PonyFlightMarks = piece.PonyFlightMarks + 1

    local hit = data.HitPos
    local dir = heading:GetNormalized()

    timer.Simple(0, function()
        util.Decal("Blood", hit - dir * 12, hit + dir * 12)
    end)
end

local GIB_PARTS = {
    { "models/gibs/HGIBS.mdl", 1 },
    { "models/gibs/HGIBS_spine.mdl", 1 },
    { "models/gibs/HGIBS_scapula.mdl", 2 },
    { "models/gibs/HGIBS_rib.mdl", 6 },
}

local function gib(ply, heading, speed)
    -- Still fatal without the mess: an ordinary death, and a pony left in one
    -- piece to ragdoll like any other.
    if not ENABLE_GORE:GetBool() then
        impactSound(ply, speed)
        ply:Kill()
        return
    end

    local pos = ply:WorldSpaceCenter()

    for _ = 1, 6 do
        local effect = EffectData()
        effect:SetOrigin(pos + VectorRand(-20, 20))
        effect:SetScale(math.random(15, 25))
        effect:SetFlags(3)
        effect:SetColor(0)
        util.Effect("bloodspray", effect, true, true)
        util.Effect("BloodImpact", effect, true, true)
    end

    -- The effects burst in place and leave nothing behind, so the mess is put
    -- on the geometry by hand. Each of these traces out from the pony and marks
    -- whatever it reaches, which is what puts blood up the wall they hit.
    util.Decal("Blood", pos, pos - Vector(0, 0, 96), ply)

    -- Into the half sphere the pony was travelling into, so the wall they hit
    -- takes the blood and the empty air behind them does not. Mirroring a
    -- random direction against the heading is enough to stay on that side.
    for _ = 1, 10 do
        local dir = VectorRand():GetNormalized()

        if dir:Dot(heading) < 0 then dir = -dir end

        util.Decal("Blood", pos, pos + dir * 220, ply)
    end

    for _, part in ipairs(GIB_PARTS) do
        for _ = 1, part[2] do
            local piece = ents.Create("prop_physics")
            piece:SetModel(part[1])
            piece:SetPos(pos + VectorRand(-15, 15))
            piece:Spawn()
            piece:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

            local phys = piece:GetPhysicsObject()

            if IsValid(phys) then
                phys:Wake()
                phys:ApplyForceCenter(VectorRand(-1, 1):GetNormalized() * math.random(3000, 8000))
                phys:SetMaterial("blood")
            end

            piece.PonyFlightMarks = 0
            piece:AddCallback("PhysicsCollide", markOnBounce)

            SafeRemoveEntityDelayed(piece, math.random(10, 15))
        end
    end

    ply:EmitSound("physics/flesh/flesh_bloody_break.wav", 100, math.random(90, 110))

    for _ = 1, 3 do
        ply:EmitSound(
            "physics/flesh/flesh_squishy_impact_hard" .. math.random(1, 4) .. ".wav",
            100, math.random(60, 80))
    end

    -- DMG_REMOVENORAGDOLL is the point of doing this through damage at all: it
    -- takes the corpse away, so the pieces are what is left.
    local damage = DamageInfo()
    damage:SetDamage(9999)
    damage:SetAttacker(ply)
    damage:SetInflictor(game.GetWorld())
    damage:SetDamageType(bit.bor(DMG_FALL, DMG_ALWAYSGIB, DMG_REMOVENORAGDOLL))
    ply:TakeDamageInfo(damage)
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
    ply.ponyFlightLastVelocity = ply:GetVelocity()

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
    ply.ponyFlightLastVelocity = nil

    hook.Run("PonyFlight_Changed", ply, false, reason)
end

hook.Remove("KeyPress", "PonyFlight.Takeoff")
hook.Add("SetupMove", "PonyFlight.Takeoff", function(ply, mv)
    -- Check before movement so the ground jump cannot count as takeoff
    if not mv:KeyPressed(IN_JUMP) or ply:OnGround() then return end
    Flight.Start(ply)
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
    local previousVelocity = ply.ponyFlightLastVelocity or velocity
    ply.ponyFlightLastSpeed = speed
    ply.ponyFlightLastHorizontal = horizontal
    ply.ponyFlightLastVelocity = Vector(velocity)

    -- Horizontal only. Gravity owns the descent now, so a fall arrives fast
    -- enough that a total-speed drop would read every landing as a crash.
    local lost = previousHorizontal - horizontal

    -- The crash does not end the flight. A pony who keeps their wings after
    -- hitting something has to pull out of it, which reads better than being
    -- dropped, and rebuilding horizontal speed is its own cooldown on hitting
    -- the same wall twice.
    if lost >= Flight.IMPACT_FLOOR then
        local crashSpeed = previous
        local crashHeading = previousVelocity:GetNormalized()

        -- Measured here, dealt next frame. Damage from inside a movement hook
        -- is not reliable, and we never confirmed it works from one.
        timer.Simple(0, function()
            if not IsValid(ply) or not ply:Alive() then return end

            if crashSpeed >= Flight.GIB_SPEED then
                gib(ply, crashHeading, crashSpeed)
                return
            end

            impactSound(ply, crashSpeed)

            -- DMG_FALL, for the grunt: the engine picks the pain sound off the
            -- damage type and DMG_GENERIC has none. Not DMG_CRUSH, which is
            -- what this wants to be -- DPP2's antipropkill zeroes any of that
            -- aimed at a player, and PonyRP reads it as a melee swing.
            local damage = DamageInfo()
            damage:SetDamage(impactDamage(crashSpeed))
            damage:SetDamageType(DMG_FALL)
            damage:SetAttacker(ply)
            damage:SetInflictor(game.GetWorld())
            damage:SetDamagePosition(ply:WorldSpaceCenter())

            ply:TakeDamageInfo(damage)
        end)
    end

    if ply:OnGround() then
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
