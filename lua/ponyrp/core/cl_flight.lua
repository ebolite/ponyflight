--[[
PonyRP pegasus flight -- client presentation.

Three jobs: put the camera behind the pony while flying, bank the body into
what it is actually doing, and make PPM2 notice that the wings should be
open.

THE BODY LEANS, THE CAMERA DOES NOT
-----------------------------------
PPM2 leans you by writing SetEyeAngles every tick, plus a permanent
sin(CurTime()) roll wobble. That fights your aim, breaks anything reading
where you are looking, and the constant roll is a reliable way to make
somepony motion sick. We never touch the view.

The body is posed through bones, not angles. PPM2 runs ManipulateBoneAngles
every frame in its own PrePlayerDraw (render.moon:275) and the engine
overwrites a player's render angles regardless, so SetRenderAngles alone
moved only the models PPM2 places itself by reading that value back -- the
cutie mark among them. We rotate bone 0 (LrigPelvis, per PPM2's own
bones_modifier.moon:58) through PPM2.SetupBones, the hook PPM2 calls between
its ResetBones and its Think so other addons can pose the pony.

ORDERING
--------
Lean is computed once per frame in Think, not in the draw hooks. Two reasons:
PPM2's PrePlayerDraw runs at priority -2 and positions the cutie mark from
render angles, so anything set during a draw hook reaches the mark a frame
late -- it visibly trailed the body. And the smoothing advances by FrameTime,
so computing it in a draw hook would step it once per render pass rather than
once per frame, which reflections and RT cameras would multiply.
]]

local Flight = PonyRP.Flight

local THIRDPERSON_VAR = "simple_thirdperson_enabled"

-- Lean limits, degrees.
local MAX_PITCH = 17
local MAX_ROLL = 21
local ROLL_GAIN = 1.6
local FORWARD_LEAN = 7      -- nose dips into forward travel, lifts going backwards
local LEAN_RESPONSE = 6     -- exponential approach per second

--[[
Off, and this is the answer to why the mark drifted out of sync.

Setting render angles moved PPM2's attached pieces back when nothing else
was leaning, which read as "render angles are how you move the mark". They
are not: those pieces are bonemerged, so they already inherit the bone lean,
and a bonemerged child also picks up the parent's render matrix. Writing
both rotated them twice, about two different pivots -- the entity origin and
the pelvis -- so they diverged from the body instead of matching it. Only
the body itself ignored the render angles, which is what made the earlier
symptom look the opposite way round.

The bones drive everything. Left as a named constant because it is the one
knob worth reaching for if attachments ever stop tracking again.
]]
local RENDER_ANGLES_MOVE_ATTACHMENTS = false

local lean = {}
local wingState = {}
local weTurnedItOn = false

--[[
Third person. Simple ThirdPerson (207948202) owns the camera; we only flip
its convar, so the player keeps their own distance, offsets and smoothing
rather than getting a second, worse camera from us. Restored only if we were
the one who turned it on -- somepony who already plays in third person should
not be dropped into first person for landing.
]]
local function setThirdPerson(enabled)
    local convar = GetConVar(THIRDPERSON_VAR)
    if not convar then return end

    if enabled then
        if convar:GetBool() then return end
        weTurnedItOn = true
        RunConsoleCommand(THIRDPERSON_VAR, "1")
    elseif weTurnedItOn then
        weTurnedItOn = false
        RunConsoleCommand(THIRDPERSON_VAR, "0")
    end
end

--[[
Wings.

PPM2 only re-reads SelectWingsType inside ApplyRace, and nothing calls that
when ppm2_fly changes -- so the spread wings appeared only when something
unrelated happened to refresh the bodygroups, which is the "sometimes" here.
We call it ourselves.

Keyed on ppm2_fly rather than our own ponyrp_flying: ppm2_fly is the value
SelectWingsType actually reads, and the two networked bools do not
necessarily land on the same frame. Watching the wrong one would refresh the
bodygroup before PPM2 could see the flag and leave the wings shut.
]]
local function applyBodygroups(ply)
    if not IsValid(ply) or not isfunction(ply.GetPonyData) then return end

    local ok, data = pcall(ply.GetPonyData, ply)
    if not ok or not data or not isfunction(data.GetBodygroupController) then return end

    local controller = data:GetBodygroupController()
    if not controller then return end

    -- ApplyRace alone sets the bodygroup on the player entity. PPM2's own
    -- data-change path calls ApplyBodygroups (data_instance.moon:309), which
    -- is the one that also reaches the merged models -- and those are what
    -- kept showing spread wings after landing. Call both, race last, so the
    -- wing selection is the final word.
    if isfunction(controller.ApplyBodygroups) then
        pcall(controller.ApplyBodygroups, controller)
    end

    if isfunction(controller.ApplyRace) then
        pcall(controller.ApplyRace, controller)
    end
end

--[[
Re-asserted across a short window rather than once.

The wings lagged both opening and closing. PPM2 rebuilds its bodygroups and
merged models on its own schedule, so a single call can be undone moments
later by a rebuild that was already in flight. Re-applying over ~0.3s means
whichever pass lands, ours is the one after it.

This cannot remove the first part of the delay: flight state is server
authoritative, so the ppm2_fly flag costs a network round trip before the
client can act on it at all. Killing that too would mean predicting takeoff
on the client and setting the wing bodygroup directly, which duplicates
PPM2's own wing-type arithmetic -- worth doing only if the remaining lag is
still objectionable.
]]
local REASSERT_AT = { 0, 0.05, 0.15, 0.3 }

local function refreshWings(ply)
    applyBodygroups(ply)

    for _, delay in ipairs(REASSERT_AT) do
        timer.Simple(delay, function() applyBodygroups(ply) end)
    end
end

local function updateLean(ply)
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

        -- Nose follows the flight path: climbing tips up, diving tips down.
        targetPitch = -math.deg(math.asin(math.Clamp(direction.z, -1, 1)))

        -- Plus a subtle tip into forward travel, so level cruising still
        -- reads as going somewhere rather than sitting still.
        targetPitch = targetPitch + direction:Dot(facing:Forward()) * FORWARD_LEAN
        targetPitch = math.Clamp(targetPitch, -MAX_PITCH, MAX_PITCH)

        -- Bank into sideways travel. Dotting against the facing's right axis
        -- means the roll reads as leaning into the turn rather than reacting
        -- a tick late to the key you pressed.
        targetRoll = math.Clamp(direction:Dot(facing:Right()) * MAX_ROLL * ROLL_GAIN, -MAX_ROLL, MAX_ROLL)

        -- Ease the lean in with speed so a slow hover does not list.
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

        if ply.ponyrpFlightRenderAngles then
            ply:SetRenderAngles(ply.ponyrpFlightRenderAngles)
            ply.ponyrpFlightRenderAngles = nil
        end
    end
end

local wasFlying = false

hook.Add("Think", "PonyRP.Flight.Presentation", function()
    local localPly = LocalPlayer()

    if IsValid(localPly) then
        local flying = Flight.IsFlying(localPly)

        if flying ~= wasFlying then
            wasFlying = flying
            setThirdPerson(flying)
        end
    end

    for _, ply in ipairs(player.GetAll()) do
        -- Wings key off PPM2's own flag, watched directly so a refresh can
        -- never run before PPM2 has the value.
        local ppm2Flying = ply:GetNW2Bool(Flight.PPM2_NW_VAR, false)

        if wingState[ply] ~= ppm2Flying then
            wingState[ply] = ppm2Flying
            refreshWings(ply)
        end

        if Flight.IsFlying(ply) then
            local state = updateLean(ply)

            if RENDER_ANGLES_MOVE_ATTACHMENTS then
                -- Set here rather than in a draw hook so PPM2's PrePlayerDraw,
                -- which runs at priority -2 and places the cutie mark, reads
                -- this frame's value instead of last frame's.
                local angles = ply:GetRenderAngles()
                ply.ponyrpFlightRenderAngles = ply.ponyrpFlightRenderAngles or angles
                ply:SetRenderAngles(Angle(state.pitch, angles.y, state.roll))
            end
        else
            clearLean(ply)
        end
    end
end)

--[[
Bone lean. Reads the state Think already computed; deliberately does not
advance it, because this hook runs once per render pass and the smoothing
must only step once per frame.

ManipulateBoneAngles takes an offset in the bone's local space, so the
world-space lean is conjugated into it as M^-1 * R * M against the bone's
world rotation. Deriving that beats guessing which way the rig's local axes
happen to point.
]]
hook.Add("PPM2.SetupBones", "PonyRP.Flight.Lean", function(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end

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

hook.Add("EntityRemoved", "PonyRP.Flight.Cleanup", function(ent)
    lean[ent] = nil
    wingState[ent] = nil
end)
