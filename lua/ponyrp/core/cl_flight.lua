--[[
PonyRP pegasus flight -- client presentation.

Two jobs: put the camera behind the pony while flying, and bank the body
into what it is actually doing.

THE BODY LEANS, THE CAMERA DOES NOT
-----------------------------------
PPM2 leans you by writing SetEyeAngles every tick, plus a permanent
sin(CurTime()) roll wobble. That fights your aim, breaks anything that reads
where you are looking, and the constant roll is a reliable way to make
somepony motion sick. We use SetRenderAngles instead, which moves the model
and nothing else: your view stays exactly where you put it, and the pony
banks underneath it.

Lean is read back out of velocity rather than out of the keys, so it
reflects where you are genuinely going -- carrying a turn, or sliding
sideways out of one, both look right without either being a special case.
]]

local Flight = PonyRP.Flight

local THIRDPERSON_VAR = "simple_thirdperson_enabled"

-- Lean limits, degrees. Generous enough to read at a distance, short of
-- the barrel roll that would make the pose look broken.
local MAX_PITCH = 35
local MAX_ROLL = 42
local LEAN_RESPONSE = 6     -- exponential approach per second

local lean = {}
local weTurnedItOn = false

--[[
Third person.

Simple ThirdPerson (207948202) owns the camera; we just flip its convar so
the player keeps their own configured distance, offsets and smoothing rather
than getting a second, worse camera from us. We only restore it if we were
the ones who turned it on -- somepony who already plays in third person
should not be dropped into first person for landing.
]]
local function setThirdPerson(enabled)
    local convar = GetConVar(THIRDPERSON_VAR)
    if not convar then return end

    if enabled then
        if convar:GetBool() then return end -- already theirs, leave it alone
        weTurnedItOn = true
        RunConsoleCommand(THIRDPERSON_VAR, "1")
    elseif weTurnedItOn then
        weTurnedItOn = false
        RunConsoleCommand(THIRDPERSON_VAR, "0")
    end
end

local wasFlying = false

hook.Add("Think", "PonyRP.Flight.ThirdPerson", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    local flying = Flight.IsFlying(ply)
    if flying == wasFlying then return end

    wasFlying = flying
    setThirdPerson(flying)
end)

--[[
Body lean.

Runs for every flying pony, not just the local one, so other pegasi bank
too. State is keyed per player and dropped when they stop flying, so a
pony who lands and takes off again starts level instead of resuming an
old lean.
]]
local function leanFor(ply)
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
        local aim = ply:EyeAngles()

        -- Nose follows the flight path: climbing tips up, diving tips down.
        targetPitch = -math.deg(math.asin(math.Clamp(direction.z, -1, 1)))
        targetPitch = math.Clamp(targetPitch, -MAX_PITCH, MAX_PITCH)

        -- Bank into sideways travel. Dotting against the view's right axis
        -- means the roll reads as "leaning into the turn" rather than
        -- reacting a tick late to the key you pressed.
        local sideways = direction:Dot(aim:Right())
        targetRoll = math.Clamp(sideways * MAX_ROLL * 1.6, -MAX_ROLL, MAX_ROLL)

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

--[[
Applying the lean.

The body is NOT moved by SetRenderAngles. PPM2 poses the pony through
ManipulateBoneAngles every frame in its own PrePlayerDraw
(render.moon:275), and the engine overwrites a player's render angles
regardless. Setting them only moved the pieces PPM2 positions itself by
reading the stored value back -- which is exactly why the cutie mark
banked and the pony did not.

So we rotate bone 0 instead, which PPM2's own bones_modifier.moon
documents as LrigPelvis, the root. PPM2 calls PPM2.SetupBones between
ResetBones and its own Think, specifically so other addons can pose the
pony; that is the sanctioned seam and it is the one we use.

ManipulateBoneAngles takes an offset in the bone's local space, so a
world-space lean has to be conjugated into it: with M the bone's world
rotation and R the lean we want in world space, the local offset is
M^-1 * R * M. Deriving it beats guessing which way round the rig's
local axes point.
]]

-- The cutie mark and PPM2's other separately-placed models follow render
-- angles, which is why they leaned when nothing else did. Keeping both in
-- sync is the point, so we still set them. If the mark now banks TWICE as
-- far as the body it is being carried by the bones as well -- set this
-- false and it will be driven by the body alone.
local RENDER_ANGLES_MOVE_ATTACHMENTS = true

local function applyLean(ply, state)
    local matrix = ply:GetBoneMatrix(0)
    if not matrix then return end

    -- The lean we want, in world space: pitch about the pony's own right
    -- axis, roll about its forward axis.
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
end

hook.Add("PPM2.SetupBones", "PonyRP.Flight.Lean", function(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end

    if not Flight.IsFlying(ply) then
        -- PPM2's ResetBones already cleared it this frame; this only matters
        -- for the frame flight ends on, and costs nothing.
        if lean[ply] then
            lean[ply] = nil
            ply:ManipulateBoneAngles(0, angle_zero)
        end
        return
    end

    applyLean(ply, leanFor(ply))
end)

hook.Add("PrePlayerDraw", "PonyRP.Flight.LeanAttachments", function(ply)
    if not RENDER_ANGLES_MOVE_ATTACHMENTS then return end
    if not Flight.IsFlying(ply) then return end

    local state = lean[ply]
    if not state then return end

    local angles = ply:GetRenderAngles()
    ply.ponyrpFlightRenderAngles = angles
    ply:SetRenderAngles(Angle(state.pitch, angles.y, state.roll))
end)

hook.Add("PostPlayerDraw", "PonyRP.Flight.LeanReset", function(ply)
    -- Render angles persist, so leaving them set would tilt whatever does
    -- follow them in every later pass this frame -- reflections included.
    if ply.ponyrpFlightRenderAngles then
        ply:SetRenderAngles(ply.ponyrpFlightRenderAngles)
        ply.ponyrpFlightRenderAngles = nil
    end
end)

hook.Add("EntityRemoved", "PonyRP.Flight.LeanCleanup", function(ent)
    lean[ent] = nil
end)
