local Flight = PonyFlight

local THIRDPERSON_VAR = "simple_thirdperson_enabled"

local ENTER_THIRDPERSON = CreateClientConVar("ponyflight_enterthirdperson", "1",
    true, false, "Switch to third person while flying")

-- The server's answer wins, so a server that forces it overrides the preference
local function wantsThirdPerson()
    return Flight.ForcesThirdPerson() or ENTER_THIRDPERSON:GetBool()
end

-- Our own flight camera, so we do not depend on Simple ThirdPerson
local CAMERA_DIST = 110
local CAMERA_HEIGHT = 12
local CAMERA_HULL = 8

-- Lean limits in degrees
local MAX_PITCH = 17
local MAX_ROLL = 21
local ROLL_GAIN = 1.6
local LEAN_RESPONSE = 6     -- exponential approach per second

-- We drive the bones for leaning, so moving render angles rotates PPM's bonemerged pieces twice
local RENDER_ANGLES_MOVE_ATTACHMENTS = false

local lean = {}
local wingState = {}
local flapVisual = {}
local weTurnedItOn = false
local wingsWanted

local function bodygroupController(ply)
    if not IsValid(ply) or not isfunction(ply.GetPonyData) then return nil end

    local data = ply:GetPonyData()
    if not data or not isfunction(data.GetBodygroupController) then return nil end

    return data:GetBodygroupController()
end

-- Simple ThirdPerson (207948202) gets the camera when it is installed, since the
-- player has already tuned its distance and smoothing to their taste. Our own
-- camera below is the fallback for anypony without it
local function simpleThirdPerson()
    return GetConVar(THIRDPERSON_VAR)
end

local function useSimpleThirdPerson(flying)
    local convar = simpleThirdPerson()
    if not convar then return end

    if flying then
        if not wantsThirdPerson() then return end
        if convar:GetBool() then return end
        weTurnedItOn = true
        RunConsoleCommand(THIRDPERSON_VAR, "1")
    elseif weTurnedItOn then
        weTurnedItOn = false
        RunConsoleCommand(THIRDPERSON_VAR, "0")
    end
end

-- Simple ThirdPerson has its own bind, so a player can turn it off underneath us
-- mid-flight and end up in first person with a camera we are not driving
local function holdSimpleThirdPerson()
    local convar = simpleThirdPerson()
    if not convar or convar:GetBool() then return end
    if not wantsThirdPerson() then return end

    RunConsoleCommand(THIRDPERSON_VAR, "1")
end

local function applyBodygroups(ply)
    local controller = bodygroupController(ply)
    if not controller or not isfunction(controller.ApplyBodygroups) then return end

    controller:ApplyBodygroups()
end

-- Reassert only the wing group before drawing, since other bodygroups are server-networked.
-- We just predict wing state locally.
local function visibleWingsValue(ply, controller)
    controller = controller or bodygroupController(ply)
    if not controller or not isfunction(controller.SelectWingsType) then return end

    local wanted = tonumber(controller:SelectWingsType())
    if not wanted then return end

    -- Get the offset ppm2_fly uses, and add it ourselves for gliding so the wings stay open without flapping
    local ppm2Spread = ply:GetNW2Bool(Flight.PPM2_NW_VAR, false) or
        (isfunction(ply.GetMoveType) and ply:GetMoveType() == MOVETYPE_NOCLIP)

    if wingsWanted(ply) and not ppm2Spread then
        wanted = wanted + PPM2.MAX_WINGS + 1
    end

    return wanted
end

local function applyVisibleWings(ply)
    if not Flight.CanFly(ply) then return end

    local controller = bodygroupController(ply)
    if not controller then return end

    -- BODYGROUP_WINGS is controller-specific: 2 on the new model, 3 on the
    -- old one. PPM2.BODYGROUP_WINGS is only the old-model default.
    local class = controller.__class
    local group = tonumber(class and class.BODYGROUP_WINGS or controller.BODYGROUP_WINGS)
    if not group or group < 0 then return end

    local wanted = visibleWingsValue(ply, controller)

    if not wanted or ply:GetBodygroup(group) == wanted then return end

    ply:SetBodygroup(group, wanted)
end

-- We reassert multiple times, because PPM2 often rebuilds bodygroups.
-- If we call just once, it can be overwritten by a PPM2 rebuild mid-flight.
local REASSERT_AT = { 0, 0.05, 0.15, 0.3 }

local function refreshWings(ply)
    applyBodygroups(ply)

    for _, delay in ipairs(REASSERT_AT) do
        timer.Simple(delay, function() applyBodygroups(ply) end)
    end
end

-- Timeout here, how long we allow the client prediction to play on its own w/o server confirmation
local PREDICTION_TIMEOUT = 0.5

local predictedAt = nil
local predictedFlying = false

local function predictFlying(flying)
    if not IsValid(LocalPlayer()) then return end

    -- Return early so we don't reset the fly animation every frame
    if predictedAt and predictedFlying == flying then return end

    predictedAt = CurTime()
    predictedFlying = flying
end

-- We recompute this every frame sort of as a brute force method to make sure
-- no weird stuff happens between PPM2 rebuilds, model changes, whatever.
-- Storing the prediction made a lot of flickering happened.
-- Still kind of janky, but whatever, it works lol
wingsWanted = function(ply)
    local base = Flight.IsFlying(ply)

    if ply ~= LocalPlayer() or not predictedAt then return base end

    if predictedFlying == base or CurTime() - predictedAt >= PREDICTION_TIMEOUT then
        predictedAt = nil
        predictedFlying = base
        return base
    end

    return predictedFlying
end

function Flight.VisualFlying(ply)
    return wingsWanted(ply)
end

-- Computed every frame for the same reasoning as wingsWanted above
local function flappingWanted(ply, flying)
    flying = flying == nil and wingsWanted(ply) or flying

    local state = flapVisual[ply]
    if not state then
        state = {
            active = false,
            startedAt = 0,
            nextBeatAt = nil
        }
        flapVisual[ply] = state
    end

    if not flying then
        state.active = false
        state.nextBeatAt = nil
        return false
    end

    local held

    if ply == LocalPlayer() then
        held = ply:KeyDown(IN_JUMP)
    else
        held = Flight.IsFlapping(ply)
    end

    local now = CurTime()

    if held then
        if not state.active then
            state.active = true
            state.startedAt = now
            state.nextBeatAt = now
        end

        if state.nextBeatAt and now >= state.nextBeatAt then
            local cycle = math.floor((now - state.startedAt) / Flight.BEAT_INTERVAL)
            local boundary = state.startedAt + cycle * Flight.BEAT_INTERVAL
            local lateness = now - boundary

            -- After a hitch, skip the stale beat rather than playing it just
            -- before the next correctly phased one.
            if lateness <= math.min(Flight.BEAT_INTERVAL * 0.25, 0.1) then
                ply:EmitSound(
                    Flight.WINGBEATS[math.random(#Flight.WINGBEATS)],
                    70,
                    math.random(94, 106),
                    Flight.BEAT_VOLUME,
                    CHAN_BODY)
            end

            state.nextBeatAt = boundary + Flight.BEAT_INTERVAL
        end
    elseif state.active then
        state.active = false
        state.nextBeatAt = nil
    end

    return state.active
end

local function enforceWings(ply)
    local flying = wingsWanted(ply)
    local wanted = flappingWanted(ply, flying)

    if ply:GetNW2Bool(Flight.PPM2_NW_VAR, false) == wanted and wingState[ply] == wanted then
        return flying, wanted
    end

    ply:SetNW2Bool(Flight.PPM2_NW_VAR, wanted)
    wingState[ply] = wanted
    refreshWings(ply)

    return flying, wanted
end

-- Predicts the same single airborne press sv_flight.lua takes off on
hook.Add("KeyPress", "PonyFlight.PredictTakeoff", function(ply, key)
    if ply ~= LocalPlayer() then return end
    if key ~= IN_JUMP then return end
    -- Only an active prediction blocks a new one
    if Flight.IsFlying(ply) or (predictedAt and predictedFlying) then return end
    if not Flight.CanFly(ply) then return end

    if not ply:OnGround() then
        predictFlying(true)
    end
end)

local function updateLean(ply, flapping)
    local state = lean[ply]

    if not state then
        state = { pitch = 0, roll = 0 }
        lean[ply] = state
    end

    local velocity = ply:GetVelocity()
    local speed = velocity:Length()
    local targetPitch, targetRoll = 0, 0

    if speed > 40 then
        local direction = velocity / speed
        local facing = Angle(0, ply:EyeAngles().y, 0)

        local forwardVelocity = direction:Dot(facing:Forward())

        -- On the pony rig, negative pitch is nose-forward
        if forwardVelocity < 0 or flapping then
            targetPitch = math.Clamp(-forwardVelocity * MAX_PITCH, -MAX_PITCH, MAX_PITCH)
        end

        -- Dotted against the facing's right axis, so the roll leans into the turn
        -- rather than reacting a tick late to the key.
        targetRoll = math.Clamp(direction:Dot(facing:Right()) * MAX_ROLL * ROLL_GAIN, -MAX_ROLL, MAX_ROLL)

        -- Ease the lean in with speed
        local authority = math.Clamp(speed / 260, 0, 1)
        targetPitch = targetPitch * authority
        targetRoll = targetRoll * authority
    end

    local fraction = 1 - math.exp(-LEAN_RESPONSE * FrameTime())
    state.pitch = Lerp(fraction, state.pitch, targetPitch)
    state.roll = Lerp(fraction, state.roll, targetRoll)

    return state
end

local function clearLean(ply)
    if not lean[ply] then return end

    lean[ply] = nil

    if IsValid(ply) then
        ply:ManipulateBoneAngles(0, angle_zero)

        if ply.ponyFlightRenderAngles then
            ply:SetRenderAngles(ply.ponyFlightRenderAngles)
            ply.ponyFlightRenderAngles = nil
        end
    end
end

local wasFlying = false
local wasOnGround = false

hook.Add("Think", "PonyFlight.Presentation", function()
    local localPly = LocalPlayer()

    if IsValid(localPly) then
        local flying = Flight.IsFlying(localPly)

        local onGround = localPly:OnGround()

        if onGround and not wasOnGround and (flying or (predictedAt and predictedFlying)) then
            predictFlying(false)
        end

        wasOnGround = onGround

        local shown = wingsWanted(localPly)

        if shown ~= wasFlying then
            wasFlying = shown
            useSimpleThirdPerson(shown)
        elseif shown then
            holdSimpleThirdPerson()
        end
    end

    for _, ply in ipairs(player.GetAll()) do
        -- Lean off the same answer the wings use
        local flying, flapping = enforceWings(ply)

        if flying then
            local state = updateLean(ply, flapping)

            if RENDER_ANGLES_MOVE_ATTACHMENTS then
                -- Before PPM2's PrePlayerDraw (priority -2, places the cutie mark),
                -- so it reads this frame's value.
                local angles = ply:GetRenderAngles()
                ply.ponyFlightRenderAngles = ply.ponyFlightRenderAngles or angles
                ply:SetRenderAngles(Angle(state.pitch, angles.y, state.roll))
            end
        else
            clearLean(ply)
        end
    end
end)

hook.Add("PPM2.SetupBones", "PonyFlight.Lean", function(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end

    -- Happens after entity networking has restored the server's bodygroup
    applyVisibleWings(ply)

    local state = lean[ply]
    if not state then return end

    local matrix = ply:GetBoneMatrix(0)
    if not matrix then return end

    local facing = Angle(0, ply:EyeAngles().y, 0)
    local world = Angle(0, 0, 0)
    world:RotateAroundAxis(facing:Forward(), state.roll)
    world:RotateAroundAxis(facing:Right(), state.pitch)

    local boneWorld = Matrix()
    boneWorld:SetAngles(matrix:GetAngles())

    local inverse = Matrix(boneWorld)
    inverse:Invert()

    local desired = Matrix()
    desired:SetAngles(world)

    ply:ManipulateBoneAngles(0, (inverse * desired * boneWorld):GetAngles())
end)

hook.Add("EntityRemoved", "PonyFlight.Cleanup", function(ent)
    lean[ent] = nil
    wingState[ent] = nil
    flapVisual[ent] = nil
end)

-- Exposed for cl_flightdebug.lua
function Flight.DebugPrediction()
    return predictedAt, predictedFlying
end

function Flight.DebugWingsWanted(ply)
    return wingsWanted(ply)
end

function Flight.DebugFlappingWanted(ply)
    return flappingWanted(ply)
end

function Flight.DebugVisibleWingsWanted(ply)
    return visibleWingsValue(ply)
end

-- Pulled in on whatever it hits so the view never ends up inside geometry
hook.Add("CalcView", "PonyFlight.Camera", function(ply, origin, angles, fov)
    if simpleThirdPerson() then return end
    if not wantsThirdPerson() then return end
    if not Flight.VisualFlying(ply) then return end

    local eyes = ply:EyePos()
    local wanted = eyes - angles:Forward() * CAMERA_DIST + angles:Up() * CAMERA_HEIGHT

    local trace = util.TraceHull({
        start = eyes,
        endpos = wanted,
        mins = Vector(-CAMERA_HULL, -CAMERA_HULL, -CAMERA_HULL),
        maxs = Vector(CAMERA_HULL, CAMERA_HULL, CAMERA_HULL),
        filter = ply
    })

    return {
        origin = trace.Hit and trace.HitPos + trace.HitNormal * CAMERA_HULL or wanted,
        angles = angles,
        fov = fov,
        drawviewer = true
    }
end)

-- A disconnect or a lua_reload mid-flight would otherwise leave them in third person
hook.Add("ShutDown", "PonyFlight.RestoreThirdPerson", function()
    useSimpleThirdPerson(false)
end)
