--[[
PonyRP pegasus flight -- shared movement.

Replaces PPM2's flight wholesale rather than patching around it. PPM2's
controller (ponyfly.moon) never actually moves the player: its FinishMove
runs its own hull trace and calls SetPos, adding raw velocity to the origin
with no frame scaling, so the "velocity" it carries is units-per-tick. Two
consequences we care about:

  - Entity velocity is meaningless while flying. Anything reading
    GetVelocity sees roughly nothing, which is why Falling Wind (2816536934)
    and Fly By Sounds (167809847) both go quiet midair. Neither addon
    excludes flight; they are handed a number in the wrong unit, an order of
    magnitude below their thresholds. PPM2 multiplies by 50 to convert back
    on landing, which is the same admission.

  - Collision is a single trace with an ad-hoc bounce, so fast flight snags
    on corners instead of sliding along them.

Here the engine does the moving. We write velocity onto the movedata and let
default movement run, so TryPlayerMove gives real collision and sliding, and
the velocity ends up on the player where every other addon can read it. The
sound addons then need no patch at all.

DISABLING PPM2
--------------
ppm2_sv_flight 0 is not sufficient. That convar guards PPM2's SetupMove hook
only; its Move and FinishMove hooks are gated purely on the ppm2_fly
networked bool, so anything that sets that bool still gets PPM2's movement
bolted on. We remove those three hooks outright and set the convar as well.

The client also replaces PPM2's CalcMainActivity hook. PPM2 couples its
noclip leg pose, disabled IK, and wing-flap gesture to ppm2_fly; PonyRP keeps
the pose and disabled IK for the whole flight while using that flag only for
the Space-held flap gesture. The clientside bodygroup override keeps the
wings spread while gliding.
]]

PonyRP = PonyRP or {}
PonyRP.Flight = PonyRP.Flight or {}

local Flight = PonyRP.Flight

-- Networked so the client's own movement prediction and everypony else's
-- rendering agree on who is flying.
Flight.NW_VAR = "ponyrp_flying"

-- Separate from flight so clients can keep the wings spread while the
-- server-owned flap gesture follows Space.
Flight.FLAP_NW_VAR = "ponyrp_flapping"

-- PPM2's visual flag. We drive it; PPM2 reads it for the pose and wings.
Flight.PPM2_NW_VAR = "ppm2_fly"

--[[
Tuning. All placeholders per spec §2 ("all flight numbers are placeholders
to be tuned in game"), and deliberately not convars -- these want to be
tried, felt, and edited, not left as a console surface.

Speeds are hu/s, so they compare directly against land speed (~200 walk,
~400 run). Pegasus cruise sits well above a sprint because flight is the
tribe's whole argument, and per your call it stays usable as an escape.
]]
Flight.SPEED = 650          -- horizontal cruise at flightSpeedMult 1
Flight.CLIMB_SPEED = 420    -- Space, "fast and vertical"
Flight.DIVE_SPEED = 780     -- Ctrl, faster than climbing because gravity helps
Flight.ACCEL = 900          -- hu/s^2 toward the wished velocity
Flight.GLIDE_DRAG = 0.55    -- per second decay when no input; low, so momentum carries
Flight.SINK = 55            -- passive sink when not climbing, so altitude costs flaps
Flight.DOUBLE_TAP = 0.32    -- seconds between the two Space presses
Flight.BEAT_INTERVAL = 0.5  -- fallback duration of one full flap sequence
Flight.BEAT_VOLUME = 0.3

-- PPM2's CalcMainActivity returns this sequence for its flight gesture.
-- SequenceDuration lets each client finish the actual model cycle instead
-- of assuming the sound cadence and animation length are identical.
Flight.FLAP_SEQUENCE = 370
Flight.FLAP_DURATION_FALLBACK = Flight.BEAT_INTERVAL
-- Sequence 370 contains two audible wing strokes.
Flight.BEATS_PER_FLAP_SEQUENCE = 2

Flight.WINGBEATS = {
    "ponyrp/wingbeat1.wav",
    "ponyrp/wingbeat2.wav",
    "ponyrp/wingbeat3.wav",
    "ponyrp/wingbeat4.wav",
    "ponyrp/wingbeat5.wav",
}

-- Resolved on call, never cached: sh_tribes.lua sorts after this file in the
-- loader's alphabetical sh_ pass, so at load time PonyRP.Tribes is still nil.
local function tribes()
    return PonyRP.Tribes
end

function Flight.CanFly(ply)
    if not IsValid(ply) or not ply:Alive() then return false end
    if ply:InVehicle() then return false end
    if ply:WaterLevel() > 0 then return false end

    local Tribes = tribes()
    if not Tribes then return false end

    return Tribes.GetStats(Tribes.GetRace(ply)).canFly == true
end

function Flight.IsFlying(ply)
    return IsValid(ply) and ply:GetNWBool(Flight.NW_VAR, false)
end

function Flight.IsFlapping(ply)
    return IsValid(ply) and ply:GetNWBool(Flight.FLAP_NW_VAR, false)
end

function Flight.FlapCycleDuration(ply)
    if IsValid(ply) and isfunction(ply.SequenceDuration) then
        local duration = tonumber(ply:SequenceDuration(Flight.FLAP_SEQUENCE))

        if duration and duration > 0.05 and duration < 5 then
            return duration
        end
    end

    return Flight.FLAP_DURATION_FALLBACK
end

-- Alicorns fly at half speed ("slow and primarily vertical", spec §2); the
-- multiplier already lives in the tribe stat table, so read it rather than
-- duplicating the balance decision here.
function Flight.SpeedMult(ply)
    local Tribes = tribes()
    if not Tribes then return 1 end
    return Tribes.GetStats(Tribes.GetRace(ply)).flightSpeedMult or 1
end

function Flight.VerticalSpeedMult(ply)
    local Tribes = tribes()
    if not Tribes then return 1 end

    local stats = Tribes.GetStats(Tribes.GetRace(ply))
    return stats.flightVerticalMult or stats.flightSpeedMult or 1
end

--[[
PPM2 teardown. Runs in both realms because movement hooks run in both, and
runs again on InitPostEntity because addon load order is not ours to
control -- removing a hook before PPM2 has added it does nothing.
]]
local function neuterPPM2Flight()
    hook.Remove("SetupMove", "PPM2.Ponyfly")
    hook.Remove("Move", "PPM2.Ponyfly")
    hook.Remove("FinishMove", "PPM2.Ponyfly")

    -- Belt and braces: kills PPM2's impulse handler and its own activation
    -- path even if the hook removal above is somehow outrun.
    if SERVER then
        local allow = GetConVar("ppm2_sv_flight")
        if allow and allow:GetInt() ~= 0 then RunConsoleCommand("ppm2_sv_flight", "0") end
    end
end

neuterPPM2Flight()
hook.Add("InitPostEntity", "PonyRP.Flight.NeuterPPM2", neuterPPM2Flight)
hook.Add("OnReloaded", "PonyRP.Flight.NeuterPPM2", neuterPPM2Flight)

--[[
The move itself.

Returning nothing rather than true is the whole point: the engine's own
movement runs afterwards with the velocity we set, which is what gives real
collision, real sliding, and a velocity other addons can read. Zeroing the
wish speeds first stops the engine's air acceleration adding its own
contribution on top of ours.
]]
hook.Add("Move", "PonyRP.Flight.Move", function(ply, mv)
    if not Flight.IsFlying(ply) then return end

    local mult = Flight.SpeedMult(ply)
    local verticalMult = Flight.VerticalSpeedMult(ply)
    local ang = mv:GetMoveAngles()
    local vel = mv:GetVelocity()
    local dt = FrameTime()

    -- Horizontal wish direction, flattened: pitching your view down should
    -- aim the dive with Ctrl, not sabotage your forward speed.
    local wish = Vector(0, 0, 0)
    local forward = ang:Forward()
    local right = ang:Right()
    forward.z = 0
    right.z = 0
    forward:Normalize()
    right:Normalize()

    if mv:KeyDown(IN_FORWARD) then wish = wish + forward end
    if mv:KeyDown(IN_BACK) then wish = wish - forward end
    if mv:KeyDown(IN_MOVERIGHT) then wish = wish + right end
    if mv:KeyDown(IN_MOVELEFT) then wish = wish - right end

    local horizontal = Vector(vel.x, vel.y, 0)

    if wish:LengthSqr() > 0 then
        wish:Normalize()
        local target = wish * Flight.SPEED * mult
        horizontal = LerpVector(math.min(Flight.ACCEL * dt / Flight.SPEED, 1), horizontal, target)
    else
        -- No input glides rather than stops, so speed feels like something
        -- you carry and spend instead of a button you hold.
        horizontal = horizontal * math.max(1 - Flight.GLIDE_DRAG * dt, 0)
    end

    local vertical = vel.z

    if mv:KeyDown(IN_JUMP) then
        vertical = Lerp(math.min(Flight.ACCEL * dt / Flight.CLIMB_SPEED, 1), vertical, Flight.CLIMB_SPEED * verticalMult)
    elseif mv:KeyDown(IN_DUCK) then
        vertical = Lerp(math.min(Flight.ACCEL * dt / Flight.DIVE_SPEED, 1), vertical, -Flight.DIVE_SPEED * verticalMult)
    else
        -- Passive sink. Holding altitude costs a flap, which is what gives
        -- the wingbeat a rhythm worth hearing.
        vertical = Lerp(math.min(dt * 2, 1), vertical, -Flight.SINK)
    end

    mv:SetForwardSpeed(0)
    mv:SetSideSpeed(0)
    mv:SetUpSpeed(0)
    mv:SetVelocity(Vector(horizontal.x, horizontal.y, vertical))
end)
