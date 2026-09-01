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
local flapVisual = {}
local weTurnedItOn = false
local wingsWanted

local function bodygroupController(ply)
    if not IsValid(ply) or not isfunction(ply.GetPonyData) then return nil end

    local data = ply:GetPonyData()
    if not data or not isfunction(data.GetBodygroupController) then return nil end

    return data:GetBodygroupController()
end

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

PPM2 couples two things to ppm2_fly: its noclip gesture makes the wings flap,
and SelectWingsType chooses the spread bodygroup. PonyRP deliberately splits
them. ponyrp_flying decides whether the wings are spread; ponyrp_flapping and
the local Space key decide whether ppm2_fly runs the gesture. The render-time
override below keeps the spread bodygroup selected when that gesture is off.

PPM2 only re-reads SelectWingsType inside ApplyRace, and nothing calls that
when ppm2_fly changes, so we still trigger its refresh on flap transitions.
Neither PPM2 flag is treated as authority: both flight and flapping derive
from PonyRP-owned state that PPM2 never writes.
]]
--[[
ApplyBodygroups, not SlowUpdate, and the difference is the reset.

Briefly this called data:SlowUpdate() -- the same entry point PPM2's own
0.5s timer uses -- on the theory that copying the working timer removed the
guesswork. It made things worse, and the diff says why:

    ApplyBodygroups = ResetBodygroups() then SlowUpdate()
    SlowUpdate      = SlowUpdate()

ResetBodygroups zeroes every bodygroup and calls ResetWings
(bodygroup_controller.moon:740-752). On the new pony model the wings are not
only a bodygroup, so ApplyRace setting BODYGROUP_WINGS is not by itself
enough to put them away -- the reset is what actually clears them. Dropping
it left nothing to undo the spread wings.
]]
local function applyBodygroups(ply)
    local controller = bodygroupController(ply)
    if not controller or not isfunction(controller.ApplyBodygroups) then return end

    controller:ApplyBodygroups()
end

-- Player bodygroups are server-networked. A clientside ApplyBodygroups can
-- therefore be correct here and still be replaced by the next snapshot of
-- the server's older value. Put back only the wing group immediately before
-- drawing; this is cheap enough to be a condition rather than another
-- cached event, and leaves every unrelated PPM/2 bodygroup alone.
local function visibleWingsValue(ply, controller)
    controller = controller or bodygroupController(ply)
    if not controller or not isfunction(controller.SelectWingsType) then return end

    local wanted = tonumber(controller:SelectWingsType())
    if not wanted then return end

    -- ppm2_fly now means "flapping", but a gliding pony still uses the
    -- spread-wing bodygroup. SelectWingsType adds this same offset while the
    -- PPM2 flag is true; add it ourselves only for the glide case.
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

--[[
Re-asserted across a short window rather than once.

The wings lagged both opening and closing. PPM2 rebuilds its bodygroups and
merged models on its own schedule, so a single call can be undone moments
later by a rebuild that was already in flight. Re-applying over ~0.3s means
whichever pass lands, ours is the one after it.

This does not address the round trip -- refreshing sooner cannot help when
the flag being refreshed from has not arrived. That is the prediction below,
which writes the flag locally so there is something true to refresh from.
The two are complementary: prediction decides WHEN the wings should change,
this decides that our answer is the one that survives PPM2's own rebuilds.
]]
local REASSERT_AT = { 0, 0.05, 0.15, 0.3 }

local function refreshWings(ply)
    applyBodygroups(ply)

    for _, delay in ipairs(REASSERT_AT) do
        timer.Simple(delay, function() applyBodygroups(ply) end)
    end
end

--[[
Predicting our own takeoff and landing, which is what makes them instant.

PPM/2's noclip is the model, and it is instant for two separate reasons.
It refreshes on the transition rather than waiting for its own timer --

    hook.Add 'PlayerNoClip', 'PPM2.WingsCheck', =>
        timer.Simple 0, -> ... bg\SlowUpdate()      -- bodygroup_controller.moon:937

-- and, the half that actually matters here, the thing it refreshes FROM is
MOVETYPE_NOCLIP, which the local player's own prediction has already changed.
Nothing is waited on because nothing had to travel.

We had the first half already, and it was never the problem. ppm2_fly is set
by the server, so no amount of refreshing beats the round trip -- refreshing
sooner only recomputes from a flag that has not arrived, and SelectWingsType
reads it as still false.

So the flag is written locally the moment the client can know, and the server
is left to confirm. Both edges are honestly predictable from what the client
already has: takeoff is the same double-tapped jump the server's KeyPress
hook watches, and CanFly reads the race NW var; landing is OnGround, which
for yourself is predicted, and which is the server's own landing test.

Only for LocalPlayer. Everypony else's takeoff is genuinely unknowable until
it is networked, and PPM/2's noclip is no different -- movetype has to travel
for other players too.
]]
local PREDICTION_TIMEOUT = 0.5

local predictedAt = nil
local predictedFlying = false

local function predictFlying(flying)
    if not IsValid(LocalPlayer()) then return end

    -- Already predicting this, so leave the window where it was. Re-arming
    -- it every frame would hold it open forever and let a guess outlast the
    -- server, which is the one thing a prediction must never do.
    if predictedAt and predictedFlying == flying then return end

    predictedAt = CurTime()
    predictedFlying = flying
end

--[[
What the wings SHOULD be, recomputed from scratch every frame.

This is the part that was not matching noclip, and the part that was
sticking. MOVETYPE_NOCLIP is not an event PPM/2 records; it is a condition
that stays true, so every ApplyRace re-derives the answer and nothing can
leave the wings wrong -- there is no stored state to go stale.

Ours stored state. predictFlying wrote ppm2_fly once and trusted it to
survive, and it does not, because PPM/2 writes that var clientside itself:

    ModelChanges   ponydata.moon:500
    PlayerRespawn  ponydata.moon:561
    PlayerDeath    ponydata.moon:590     -- all @ent\SetNW2Bool('ppm2_fly', false)

Every one of those shuts the wings mid-flight, and since the SERVER's copy
never changed, it never re-sends and nothing ever puts them back. Stuck
closed. The old reconcile could do the same in reverse -- on a slow landing
confirmation it flipped its own guess back and wrote a stale true that the
server would likewise never contradict. Stuck open on landing.

So nothing is stored now. ponyrp_flying is the base -- it is ours, the server
owns it, and PPM/2 has never heard of it, so nothing else writes it. The
prediction is a bounded override on top, live only until the server catches
up or the window lapses, so it can never outlive its usefulness or win an
argument against the server.
]]
wingsWanted = function(ply)
    local base = Flight.IsFlying(ply)

    if ply ~= LocalPlayer() or not predictedAt then return base end

    -- Retiring the prediction resets the guess to reality as well as clearing
    -- the window. Leaving predictedFlying latched at its last value is what
    -- made a second takeoff slow: the KeyPress guard below reads it, so a
    -- flight that ended by any route other than the ground edge -- death,
    -- gib, vehicle, race change -- left it stuck true and silently declined
    -- to predict ever again. That is a delay only the flier can see, because
    -- only the flier has a prediction to lose.
    if predictedFlying == base or CurTime() - predictedAt >= PREDICTION_TIMEOUT then
        predictedAt = nil
        predictedFlying = base
        return base
    end

    return predictedFlying
end

--[[
Assert the PPM2 flap flag every frame, for every pony.

Cheap -- a bool compare per player, and the write and rebuild only happen on
the frames where something has actually knocked the value off. That makes the
correction self-healing rather than one-shot: whatever clobbers ppm2_fly, and
there are at least four things that do, it is right again the next frame
instead of until the next time the server happens to change its mind.

This is what carries other ponies too. Their base is the networked
ponyrp_flapping, so PPM/2 zeroing ppm2_fly while a pegasus is actively
flapping heals in a frame, where before it could be permanent.
]]
local function flappingWanted(ply, flying)
    flying = flying == nil and wingsWanted(ply) or flying

    local state = flapVisual[ply]
    if not state then
        state = {
            active = false,
            startedAt = 0,
            stopAt = nil,
            duration = Flight.FLAP_DURATION_FALLBACK,
            beatInterval = Flight.FLAP_DURATION_FALLBACK / Flight.BEATS_PER_FLAP_SEQUENCE,
            nextBeatAt = nil
        }
        flapVisual[ply] = state
    end

    -- Landing and every forced flight exit still stop immediately. The
    -- cycle completion is only for releasing Space during an active flight.
    if not flying then
        state.active = false
        state.stopAt = nil
        state.nextBeatAt = nil
        return false
    end

    -- Local buttons are predicted; every other player's held state comes
    -- from the server. Each client owns the visual latch, so network delay
    -- cannot make a remote gesture get cut at the server's cycle boundary.
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
            state.duration = Flight.FlapCycleDuration(ply)
            state.beatInterval = state.duration / Flight.BEATS_PER_FLAP_SEQUENCE
            state.nextBeatAt = now
        end

        -- Pressing Space again while the last cycle is finishing simply
        -- resumes the already-running gesture.
        state.stopAt = nil

        if state.nextBeatAt and now >= state.nextBeatAt then
            local cycle = math.floor((now - state.startedAt) / state.beatInterval)
            local boundary = state.startedAt + cycle * state.beatInterval
            local lateness = now - boundary

            -- A normal frame lands just after the boundary. After a long
            -- hitch, skip the stale beat rather than playing it immediately
            -- before the next correctly phased one.
            if lateness <= math.min(state.beatInterval * 0.25, 0.1) then
                ply:EmitSound(
                    Flight.WINGBEATS[math.random(#Flight.WINGBEATS)],
                    70,
                    math.random(94, 106),
                    Flight.BEAT_VOLUME,
                    CHAN_BODY)
            end

            state.nextBeatAt = boundary + state.beatInterval
        end
    elseif state.active then
        if not state.stopAt then
            local elapsed = math.max(now - state.startedAt, 0)
            local cycles = math.max(math.ceil(elapsed / state.duration), 1)
            state.stopAt = state.startedAt + cycles * state.duration
        end

        if now >= state.stopAt then
            state.active = false
            state.stopAt = nil
            state.nextBeatAt = nil
        end
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

--[[
Flight activity, independently of the flap gesture.

PPM/2's CalcMainActivity couples both to ppm2_fly: true selects sequence 370
and starts ACT_GMOD_NOCLIP_LAYER as a gesture; false removes the gesture,
restores IK, and falls through to the standing activity. That made releasing
Space straighten the legs even though PonyRP flight was still active.

Take ownership of that hook so the base activity and IK follow flying, while
only the gesture follows ppm2_fly. The same isPlayingPPM2Anim marker PPM/2
uses makes hot reload clean up a gesture started by either implementation.
]]
local function removePPM2FlightActivity()
    hook.Remove("CalcMainActivity", "PPM2.Ponyfly")
end

removePPM2FlightActivity()
timer.Simple(0, removePPM2FlightActivity)
hook.Add("InitPostEntity", "PonyRP.Flight.NeuterPPM2Activity", function()
    timer.Simple(0, removePPM2FlightActivity)
end)
hook.Add("OnReloaded", "PonyRP.Flight.NeuterPPM2Activity", function()
    timer.Simple(0, removePPM2FlightActivity)
end)

hook.Add("CalcMainActivity", "PonyRP.Flight.Activity", function(ply)
    local flying = wingsWanted(ply)
    local isNewPony = not isfunction(ply.IsNewPonyCached) or ply:IsNewPonyCached()

    if not flying or not isNewPony then
        if not ply.ponyrpFlightActivity then return end

        ply.ponyrpFlightActivity = nil

        if ply.isPlayingPPM2Anim then
            ply.isPlayingPPM2Anim = false
            ply:AnimResetGestureSlot(GESTURE_SLOT_CUSTOM)
        end

        ply:SetIK(true)
        return
    end

    ply.ponyrpFlightActivity = true

    if ply:GetNW2Bool(Flight.PPM2_NW_VAR, false) then
        if not ply.isPlayingPPM2Anim then
            ply.isPlayingPPM2Anim = true
            ply:AnimRestartGesture(GESTURE_SLOT_CUSTOM, ACT_GMOD_NOCLIP_LAYER, false)
        end
    elseif ply.isPlayingPPM2Anim then
        ply.isPlayingPPM2Anim = false
        ply:AnimResetGestureSlot(GESTURE_SLOT_CUSTOM)
    end

    -- Ground IK is what pulls the legs back toward their standing pose. Keep
    -- it disabled for the entire flight, not merely while Space is held.
    ply:SetIK(false)
    return ACT_GMOD_NOCLIP_LAYER, Flight.FLAP_SEQUENCE
end)

-- The same double tap sv_flight.lua's KeyPress hook watches, on the same
-- terms, so the two sides reach the same answer from the same inputs rather
-- than one guessing at the other.
local lastJump = 0

hook.Add("KeyPress", "PonyRP.Flight.PredictTakeoff", function(ply, key)
    if ply ~= LocalPlayer() then return end
    if key ~= IN_JUMP then return end
    -- Only an ACTIVE prediction blocks a new one. Testing predictedFlying on
    -- its own tested a stale guess and refused to predict at all.
    if Flight.IsFlying(ply) or (predictedAt and predictedFlying) then return end
    if not Flight.CanFly(ply) then return end

    if not ply:OnGround() and CurTime() - lastJump <= Flight.DOUBLE_TAP then
        lastJump = 0
        predictFlying(true)
    else
        lastJump = CurTime()
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

        -- Forward pitch is the powered-flight pose and relaxes while gliding.
        -- Backward travel always pitches the other way, so reversing never
        -- reads as another forward lean. The sign matches the pony rig:
        -- negative pitch is nose-forward, positive is rump-forward.
        if forwardVelocity < 0 or flapping then
            targetPitch = math.Clamp(-forwardVelocity * MAX_PITCH, -MAX_PITCH, MAX_PITCH)
        end

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
local wasOnGround = false

hook.Add("Think", "PonyRP.Flight.Presentation", function()
    local localPly = LocalPlayer()

    if IsValid(localPly) then
        local flying = Flight.IsFlying(localPly)

        -- Landing is the server's own exit test -- sv_flight.lua's FinishMove
        -- stops flight on OnGround and nothing else -- and OnGround for
        -- yourself is predicted, so the client reaches that answer at the same
        -- instant rather than being told about it a round trip later.
        --
        -- On the edge, like PlayerNoClip, not on the condition. Landing is one
        -- moment; predicting it again every frame we remain stood there would
        -- keep re-arming the window against a server that has not agreed yet.
        --
        -- Resolved before the camera below, so the camera acts on this frame's
        -- prediction rather than last frame's.
        local onGround = localPly:OnGround()

        if onGround and not wasOnGround and (flying or (predictedAt and predictedFlying)) then
            predictFlying(false)
        end

        wasOnGround = onGround

        --[[
        The camera swings on the predicted state, not the server's.

        This is the other half of a delay only the flier sees, and the larger
        half: in first person there are no wings on screen to be quick about.
        Whatever the bodygroup does, you cannot see your own pony until the
        third person camera has pulled out, so gating that on the un-predicted
        ponyrp_flying spent the whole round trip before the flight became
        visible at all -- while everypony else, already looking at you, saw
        the wings open immediately.

        Predicting the wings and not the camera meant the one pony who could
        not benefit from the prediction was the one it was for.
        ]]
        local shown = wingsWanted(localPly)

        if shown ~= wasFlying then
            wasFlying = shown
            setThirdPerson(shown)
        end
    end

    for _, ply in ipairs(player.GetAll()) do
        -- Lean off the same answer the wings use, so the body banks on the
        -- prediction too rather than a round trip behind its own wings.
        local flying, flapping = enforceWings(ply)

        if flying then
            local state = updateLean(ply, flapping)

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

    -- PPM2 calls SetupBones from its PrePlayerDraw, after ordinary entity
    -- networking has had its chance to restore the server's stale bodygroup.
    -- Correcting here makes the predicted value the one this render uses.
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

hook.Add("EntityRemoved", "PonyRP.Flight.Cleanup", function(ent)
    lean[ent] = nil
    wingState[ent] = nil
    flapVisual[ent] = nil
end)

-- Exposed for cl_flightdebug.lua. The prediction is two file-locals, and the
-- one question worth asking is whether they are live at the moment the wings
-- are wrong -- which is not answerable from outside without this.
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
