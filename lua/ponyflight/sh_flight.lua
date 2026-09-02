PonyFlight = PonyFlight or {}

local Flight = PonyFlight

Flight.NW_VAR = "ponyflight_flying"

Flight.FLAP_NW_VAR = "ponyflight_flapping"

-- PPM2's own flag. We drive it; it reads this for the pose and wings.
Flight.PPM2_NW_VAR = "ppm2_fly"

Flight.FORCE_THIRDPERSON_VAR = "ponyflight_forcethirdperson"

-- Server-created only. A replicated convar reaches the client on its own, and
-- creating it on both sides is what GMod tells you not to do
if SERVER then
    CreateConVar(Flight.FORCE_THIRDPERSON_VAR, "0",
        bit.bor(FCVAR_REPLICATED, FCVAR_NOTIFY),
        "Force third person while flying, and hold players in it")
end

function Flight.ForcesThirdPerson()
    local convar = GetConVar(Flight.FORCE_THIRDPERSON_VAR)
    return convar ~= nil and convar:GetBool()
end

-- Speeds in hu/s: land speed is ~200 walking, ~400 running
Flight.SPEED = 650          -- base horizontal flight speed
Flight.CLIMB_SPEED = 420    -- lift target, not achieved climb -- gravity takes most of it
Flight.ACCEL = 900          -- in hu/s^2
Flight.GLIDE_DRAG = 0.55    -- per second decay
Flight.BEAT_VOLUME = 0.3    -- volume of the wingbeat sfx

-- wing_open_l repeats every 20 frames
-- the flap is a gesture, so we can't read it from the player sequence table
Flight.BEAT_INTERVAL = 2 / 3  -- one wingbeat: 20 frames of the 30fps flap loop

Flight.WINGBEATS = {
    "ponyflight/wingbeat1.wav",
    "ponyflight/wingbeat2.wav",
    "ponyflight/wingbeat3.wav",
    "ponyflight/wingbeat4.wav",
    "ponyflight/wingbeat5.wav",
}

local function ppm2Race(ply)
    if not IsValid(ply) or not ply.GetPonyData then return nil end

    local data = ply:GetPonyData()
    if not data or not isfunction(data.GetRace) then return nil end

    return data:GetRace()
end

local DEFAULT_PROVIDER = {
    CanFly = function(ply)
        local race = ppm2Race(ply)
        return race == "PEGASUS" or race == "ALICORN"
    end,
    SpeedMult = function() return 1 end,
    VerticalSpeedMult = function() return 1 end,
}

local FIELDS = { "CanFly", "SpeedMult", "VerticalSpeedMult" }

local activeProvider = DEFAULT_PROVIDER
local activeName = "default"

function Flight.SetProvider(name, provider)
    if not isstring(name) then
        error("PonyFlight.SetProvider: name must be a string", 2)
    end

    if not istable(provider) then
        error("PonyFlight.SetProvider: provider must be a table", 2)
    end

    local resolved = {}

    for _, field in ipairs(FIELDS) do
        local fn = provider[field]

        if fn ~= nil and not isfunction(fn) then
            error(("PonyFlight.SetProvider: %s.%s must be a function or nil")
                :format(name, field), 2)
        end

        resolved[field] = fn or DEFAULT_PROVIDER[field]
    end

    if activeName ~= "default" and activeName ~= name then
        ErrorNoHalt(("[PonyFlight] '%s' is replacing '%s' as the flight " ..
            "provider; only one can own it.\n"):format(name, activeName))
    end

    activeProvider = resolved
    activeName = name

    hook.Run("PonyFlight_ProviderChanged", name)
end

function Flight.ClearProvider()
    activeProvider = DEFAULT_PROVIDER
    activeName = "default"

    hook.Run("PonyFlight_ProviderChanged", "default")
end

function Flight.GetProviderName()
    return activeName
end

function Flight.CanFly(ply)
    if not IsValid(ply) or not ply:Alive() then return false end
    if ply:InVehicle() then return false end
    if ply:WaterLevel() > 0 then return false end
    if ply:GetMoveType() == MOVETYPE_NOCLIP then return false end

    return activeProvider.CanFly(ply) == true
end

function Flight.IsFlying(ply)
    return IsValid(ply) and ply:GetNWBool(Flight.NW_VAR, false)
end

function Flight.IsFlapping(ply)
    return IsValid(ply) and ply:GetNWBool(Flight.FLAP_NW_VAR, false)
end


function Flight.SpeedMult(ply)
    return tonumber(activeProvider.SpeedMult(ply)) or 1
end

function Flight.VerticalSpeedMult(ply)
    return tonumber(activeProvider.VerticalSpeedMult(ply)) or 1
end

-- Remove all the PPM2 flight hooks, since we replace the system entirely
local function neuterPPM2Flight()
    hook.Remove("SetupMove", "PPM2.Ponyfly")
    hook.Remove("Move", "PPM2.Ponyfly")
    hook.Remove("FinishMove", "PPM2.Ponyfly")

    hook.Remove("CalcMainActivity", "PPM2.Ponyfly")

    if SERVER then
        local allow = GetConVar("ppm2_sv_flight")
        if allow and allow:GetInt() ~= 0 then RunConsoleCommand("ppm2_sv_flight", "0") end
    end
end

-- We wait a tick for PPM2 to actually add the hooks to avoid a race
local function neuterPPM2FlightSoon()
    neuterPPM2Flight()
    timer.Simple(0, neuterPPM2Flight)
end

neuterPPM2FlightSoon()
hook.Add("InitPostEntity", "PonyFlight.NeuterPPM2", neuterPPM2FlightSoon)
hook.Add("OnReloaded", "PonyFlight.NeuterPPM2", neuterPPM2FlightSoon)

-- Reading the animation sequence from PPM2 returns 370 (a head bob) here for some reason, so we just take the noclip pose
function Flight.VisualFlying(ply)
    return Flight.IsFlying(ply)
end

hook.Add("CalcMainActivity", "PonyFlight.Activity", function(ply)
    local flying = Flight.VisualFlying(ply)
    local isNewPony = not isfunction(ply.IsNewPonyCached) or ply:IsNewPonyCached()

    if not flying or not isNewPony then
        if not ply.ponyFlightActivity and not ply.isPlayingPPM2Anim then return end

        ply.ponyFlightActivity = nil
        ply.isPlayingPPM2Anim = false
        ply:AnimResetGestureSlot(GESTURE_SLOT_CUSTOM)

        if CLIENT then ply:SetIK(true) end
        return
    end

    -- We restart the flap gesture every frame to get the open wings, since it's frame 0 of the gesture
    -- Gestures are hard to control finely, but we can kind of hack it with this.
    local flapping = ply:GetNW2Bool(Flight.PPM2_NW_VAR, false)

    if not ply.ponyFlightActivity or not ply.isPlayingPPM2Anim or not flapping then
        ply.ponyFlightActivity = true
        ply.isPlayingPPM2Anim = true
        ply:AnimRestartGesture(GESTURE_SLOT_CUSTOM, ACT_GMOD_NOCLIP_LAYER, false)
    end

    -- Disable IK during flight (IK is client-only)
    if CLIENT then ply:SetIK(false) end

    -- -1 is the base gamemode's "leave the sequence alone" sentinel.
    return ACT_MP_STAND_IDLE, -1
end)

-- Set the movement vectors for the engine to read during its movement
-- As opposed to PPM/2's flight, ours actually lets the engine move the pony and determine collisions/sliding
-- VisualFlying, not IsFlying: the networked flag takes a round trip, and the
-- client would spend it not climbing while the server already is
hook.Add("Move", "PonyFlight.Move", function(ply, mv)
    if not Flight.VisualFlying(ply) then return end

    local mult = Flight.SpeedMult(ply)
    local verticalMult = Flight.VerticalSpeedMult(ply)
    local ang = mv:GetMoveAngles()
    local vel = mv:GetVelocity()
    local dt = FrameTime()

    -- Flatten the vector so we aim descent rather than killing our speed
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
        horizontal = horizontal * math.max(1 - Flight.GLIDE_DRAG * dt, 0)
    end

    local vertical = vel.z

    -- Only lift is ours. Left alone, the engine's own gravity does the falling,
    -- so a flying pony drops no faster than anypony else
    if mv:KeyDown(IN_JUMP) then
        vertical = Lerp(math.min(Flight.ACCEL * dt / Flight.CLIMB_SPEED, 1), vertical, Flight.CLIMB_SPEED * verticalMult)
    end

    mv:SetForwardSpeed(0)
    mv:SetSideSpeed(0)
    mv:SetUpSpeed(0)
    mv:SetVelocity(Vector(horizontal.x, horizontal.y, vertical))
end)
