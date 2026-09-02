PonyFlight = PonyFlight or {}

local Flight = PonyFlight

Flight.NW_VAR = "ponyflight_flying"

Flight.FLAP_NW_VAR = "ponyflight_flapping"

-- PPM2's own flag. We drive it; it reads this for the pose and wings.
Flight.PPM2_NW_VAR = "ppm2_fly"

-- Speeds are hu/s: land speed is ~200 walking, ~400 running.
Flight.SPEED = 650          -- horizontal cruise at flightSpeedMult 1
Flight.CLIMB_SPEED = 420    -- Space, "fast and vertical"
Flight.DIVE_SPEED = 780     -- Ctrl, faster than climbing because gravity helps
Flight.ACCEL = 900          -- hu/s^2 toward the wished velocity
Flight.GLIDE_DRAG = 0.55    -- per second decay when no input; low, so momentum carries
Flight.SINK = 55            -- passive sink when not climbing, so altitude costs flaps
Flight.DOUBLE_TAP = 0.32    -- seconds between the two Space presses
Flight.BEAT_VOLUME = 0.3

-- Measured off player_default_base_new.mdl seq[1]: wing_open_l repeats
-- every 20 frames of a 30fps loop. Not SequenceDuration -- the flap is a
-- gesture layer, so the player's own sequence table cannot see it.
Flight.BEAT_INTERVAL = 2 / 3  -- one wingbeat: 20 frames of the 30fps flap loop
Flight.FLAP_CYCLE_BEATS = 1   -- releasing Space finishes the stroke in progress
Flight.FLAP_CYCLE = Flight.BEAT_INTERVAL * Flight.FLAP_CYCLE_BEATS

Flight.WINGBEATS = {
    "ponyflight/wingbeat1.wav",
    "ponyflight/wingbeat2.wav",
    "ponyflight/wingbeat3.wav",
    "ponyflight/wingbeat4.wav",
    "ponyflight/wingbeat5.wav",
}

-- Providers are asked in both realms, because the move is predicted. A
-- provider reading server-only state will rubber-band.
local FLYING_RACES = {
    PEGASUS = true,
    ALICORN = true,
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
        return race ~= nil and FLYING_RACES[race] == true
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

-- ppm2_sv_flight only guards SetupMove; Move and FinishMove gate on the
-- ppm2_fly bool alone, so the hooks have to go too. Both realms.
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

-- A tick later too: removing a hook PPM2 has not added yet does nothing.
local function neuterPPM2FlightSoon()
    neuterPPM2Flight()
    timer.Simple(0, neuterPPM2Flight)
end

neuterPPM2FlightSoon()
hook.Add("InitPostEntity", "PonyFlight.NeuterPPM2", neuterPPM2FlightSoon)
hook.Add("OnReloaded", "PonyFlight.NeuterPPM2", neuterPPM2FlightSoon)

-- PPM2 returns a 370 sequence override here; 370 is ACT_HEADBOB, not a
-- flight sequence. Return what noclip returns and the gesture is the pose.
function Flight.VisualFlying(ply)
    return Flight.IsFlying(ply)
end

hook.Add("CalcMainActivity", "PonyFlight.Activity", function(ply)
    local flying = Flight.VisualFlying(ply)
    local isNewPony = not isfunction(ply.IsNewPonyCached) or ply:IsNewPonyCached()

    if not flying or not isNewPony then
        -- PPM2's flag too, so a gesture it started before our hook removal
        -- landed gets cleaned up rather than left running.
        if not ply.ponyFlightActivity and not ply.isPlayingPPM2Anim then return end

        ply.ponyFlightActivity = nil
        ply.isPlayingPPM2Anim = false
        ply:AnimResetGestureSlot(GESTURE_SLOT_CUSTOM)

        if CLIENT then ply:SetIK(true) end
        return
    end

    -- Restarting sets the cycle to 0, so restarting every frame while not
    -- flapping pins the loop there -- which is where the wings sit open.
    -- AnimSetGestureCycle does not hold; the layer advances past it.
    local flapping = ply:GetNW2Bool(Flight.PPM2_NW_VAR, false)

    if not ply.ponyFlightActivity or not ply.isPlayingPPM2Anim or not flapping then
        ply.ponyFlightActivity = true
        ply.isPlayingPPM2Anim = true
        ply:AnimRestartGesture(GESTURE_SLOT_CUSTOM, ACT_GMOD_NOCLIP_LAYER, false)
    end

    -- Whole flight, not just while flapping. SetIK is clientside-only.
    if CLIENT then ply:SetIK(false) end

    -- -1 is the base gamemode's "leave the sequence alone" sentinel.
    return ACT_MP_STAND_IDLE, -1
end)

-- Returns nothing, not true: the engine's own movement runs afterwards with
-- the velocity set here, which is what gives real collision and sliding.
hook.Add("Move", "PonyFlight.Move", function(ply, mv)
    if not Flight.IsFlying(ply) then return end

    local mult = Flight.SpeedMult(ply)
    local verticalMult = Flight.VerticalSpeedMult(ply)
    local ang = mv:GetMoveAngles()
    local vel = mv:GetVelocity()
    local dt = FrameTime()

    -- Flattened, so looking down aims the dive rather than killing forward speed.
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

    if mv:KeyDown(IN_JUMP) then
        vertical = Lerp(math.min(Flight.ACCEL * dt / Flight.CLIMB_SPEED, 1), vertical, Flight.CLIMB_SPEED * verticalMult)
    elseif mv:KeyDown(IN_DUCK) then
        vertical = Lerp(math.min(Flight.ACCEL * dt / Flight.DIVE_SPEED, 1), vertical, -Flight.DIVE_SPEED * verticalMult)
    else
        vertical = Lerp(math.min(dt * 2, 1), vertical, -Flight.SINK)
    end

    mv:SetForwardSpeed(0)
    mv:SetSideSpeed(0)
    mv:SetUpSpeed(0)
    mv:SetVelocity(Vector(horizontal.x, horizontal.y, vertical))
end)
