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

Its CalcMainActivity hook goes the same way, and this file replaces it --
in both realms, which is the point; see the flight activity section below.
PPM2 couples its noclip leg pose, disabled IK, and wing-flap gesture to
ppm2_fly; PonyRP keeps the pose and disabled IK for the whole flight while
using that flag only for the Space-held flap gesture. The clientside
bodygroup override keeps the wings spread while gliding.
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
Flight.BEAT_VOLUME = 0.3

--[[
Wingbeat cadence, measured off the flap itself.

This used to read SequenceDuration(370), on the stated belief that 370 was
the flight animation and "contains two audible wing strokes". 370 is
ACT_HEADBOB, so the cadence was being timed to a head-bob loop -- and
1.333s / 2 = 0.6666s, which happened to be right, for no reason.

Replacing it with a round 0.5 was therefore a regression, audible as beats
drifting against the wings. The real number, decoded from the flap:

    player_default_base_new.mdl seq[1], 61 frames @ 30fps = 2.0s, looping
    wing_open_l repeats every 20 frames -> three wingbeats per loop
    one wingbeat = 20/30 = 0.6667s

Still a constant rather than a SequenceDuration call, because the flap is a
gesture layer and not the main sequence, so SequenceDuration on the player
cannot see it -- reading it would mean hardcoding a second sequence index,
which is the mistake that produced 370. A measured constant with the
measurement written down is the honest form.

Phase stays aligned for free: gliding pins the loop at frame 0 (see the
flight pose section), so pressing Space resumes the animation from a stroke
boundary at the same instant the first beat plays.
]]
Flight.BEAT_INTERVAL = 2 / 3  -- one wingbeat: 20 frames of the 30fps flap loop
Flight.FLAP_CYCLE_BEATS = 1   -- releasing Space finishes the stroke in progress
Flight.FLAP_CYCLE = Flight.BEAT_INTERVAL * Flight.FLAP_CYCLE_BEATS

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

    -- CalcMainActivity too, and in BOTH realms -- see the flight activity
    -- section below for why removing it clientside alone was not enough.
    hook.Remove("CalcMainActivity", "PPM2.Ponyfly")

    -- Belt and braces: kills PPM2's impulse handler and its own activation
    -- path even if the hook removal above is somehow outrun.
    if SERVER then
        local allow = GetConVar("ppm2_sv_flight")
        if allow and allow:GetInt() ~= 0 then RunConsoleCommand("ppm2_sv_flight", "0") end
    end
end

-- Run again a tick after each of these. Removing a hook before PPM2 has
-- added it does nothing, and PPM2 adding one back after InitPostEntity has
-- already fired is exactly the case the immediate calls cannot cover.
local function neuterPPM2FlightSoon()
    neuterPPM2Flight()
    timer.Simple(0, neuterPPM2Flight)
end

neuterPPM2FlightSoon()
hook.Add("InitPostEntity", "PonyRP.Flight.NeuterPPM2", neuterPPM2FlightSoon)
hook.Add("OnReloaded", "PonyRP.Flight.NeuterPPM2", neuterPPM2FlightSoon)

--[[
Flight pose: one gesture, held for the whole flight.

WHAT THE POSE ACTUALLY IS
-------------------------
One gesture, and it drives the legs AND the wings. That single fact is
what both of the bugs below are made of.

Searching models/ppm/pony_anims_rev.mdl -- the shared animation model, all
380 sequences -- for fly/wing/glide/hover/flap finds nothing, and none of
its sequences animate a wing bone. The flap is not in there. It is in the
player model's OWN sequence table:

    player_default_base_new.mdl  seq[1] gmod_breath_noclip_layer
        61 frames @ 30fps = 2.0s, looping
        animates: spine, neck, skull, all four legs,
                  wing_open_l, wing_open_r

Both models declare a sequence by that name, and the player model's copy
wins the merge, so ACT_GMOD_NOCLIP_LAYER resolves to index 1 and the flap
comes with it. A noclipping pegasus flaps for exactly this reason.

What makes a pony look airborne is therefore the same thing that makes any
GMod player look airborne while noclipping -- three lines in the base
gamemode (gamemodes/base/gamemode/animations.lua, HandlePlayerNoClipping):

    ply:AnimRestartGesture(GESTURE_SLOT_CUSTOM, ACT_GMOD_NOCLIP_LAYER, false)
    if CLIENT then ply:SetIK(false) end
    -- ...and it returns true, leaving CalcIdeal at ACT_MP_STAND_IDLE
    --    and CalcSeqOverride at -1.

The gesture IS the pose. No sequence override is involved, and PPM/2's
flight was a reimplementation of exactly this.

THE 370
-------
PPM/2 adds `return ACT_GMOD_NOCLIP_LAYER, 370` on top of those lines
(ponyfly.moon:300), and PonyRP inherited the constant. 370 is not a
flight sequence on any pony model:

    player_default_base_new     [370] = ACT_HEADBOB   (41f @ 30fps, 1.333s)
    player_default_base_new_nj  [370] = ACT_HEADBOB
    player_default_base (old)   [370] = swim_all

ACT_GMOD_NOCLIP_LAYER itself resolves to sequence 1. So the base layer
under every flight was a looping idle head-bob, visible through the head
and neck the whole time and completely exposed the moment the gesture
stopped. That is the "random head bobbing", and it is why the sequence
override is gone below: this returns what noclip returns.

THE LEGS, THE WINGS, AND WHY THEY FOUGHT
----------------------------------------
The gesture was tied to ppm2_fly, which since the flap rework means
"Space is held", not "flying". Releasing Space ran AnimResetGestureSlot,
which did two things at once because the layer does two things at once:

    wings  stopped moving and settled to the pose the base sequence
           leaves them in -- wings up. This is CORRECT and wanted:
           a gliding pegasus holds them open and still.
    legs   lost their only pose and fell back to the base sequence --
           standing, in mid-air. This is the bug.

So they are not two behaviours. They are one layer, wanted at two
different rates: the legs want it applied for the whole flight, the wings
want it advancing only while Space is held.

Removing the gesture gives correct wings and broken legs. Running it
continuously gives correct legs and wings that never stop beating. Both
have now been tried, and neither is available as a fix.

Pinning the loop at frame 0 is what separates them, and frame 0 is not a
guess. The wings settle where they used to because no other sequence
animates wing_open_l/r, so dropping the gesture returned that bone to its
bind pose -- and the bind pose IS frame 0 of the flap:

    bind/reference   (0.00, -90.00, -85.81)
    flap frame 0     (0.00, -90.00, -85.63)   -- animvalue rounding

So holding the loop at frame 0 reproduces the old wings exactly, while the
gesture stays applied and the legs keep their pose.

It is done by restarting the gesture every frame while gliding, not by
AnimSetGestureCycle -- that was tried and does not hold, because the layer
advances itself after we write to it. AnimRestartGesture sets the cycle to
0 by definition, so restarting per frame pins it there by construction,
using the one call already known to work. While flapping we simply stop
restarting and let the loop run.

Two earlier attempts missed all of this by looking at the base activity,
which was never the carrier of anything. And gesture slots and the chosen
sequence are both server authority -- AnimRestartGesture,
AnimResetGestureSlot and AnimRestartGesture replicate, and the sequence
is a networked var -- so a clientside-only correction could not have won
regardless of what it did.

ppm2_fly keeps its narrower job: the wing bodygroup variant, the wingbeat
sound, and now whether the loop advances.

Shared, and PPM/2's own hook removed on both sides above, because the
server ran its copy too and replicated the result over ours.

VisualFlying is the seam. The server has only the authoritative answer
and needs no other; the client overrides it with its takeoff/landing
prediction (cl_flight.lua) so the pose changes on the same frame as the
wings and the camera.

SetIK is clientside-only in GMod -- the base gamemode guards its own call
the same way -- so the guards below are load-bearing, not tidiness.
]]
function Flight.VisualFlying(ply)
    return Flight.IsFlying(ply)
end

hook.Add("CalcMainActivity", "PonyRP.Flight.Activity", function(ply)
    local flying = Flight.VisualFlying(ply)
    local isNewPony = not isfunction(ply.IsNewPonyCached) or ply:IsNewPonyCached()

    if not flying or not isNewPony then
        -- isPlayingPPM2Anim is tested as well as our own flag so a gesture
        -- started by PPM/2 -- before our hook removal landed, or across a
        -- hot reload -- is cleaned up rather than left running forever.
        if not ply.ponyrpFlightActivity and not ply.isPlayingPPM2Anim then return end

        ply.ponyrpFlightActivity = nil
        ply.isPlayingPPM2Anim = false
        ply:AnimResetGestureSlot(GESTURE_SLOT_CUSTOM)

        if CLIENT then ply:SetIK(true) end
        return
    end

    -- Three reasons to restart, and the third is the wing hold:
    --
    --   entering flight        -- ponyrpFlightActivity is not set yet
    --   something cleared the  -- isPlayingPPM2Anim is checked as well as our
    --   gesture mid-flight        own flag, so a pony does not glide in a
    --                             standing pose until they land
    --   not flapping           -- restarting sets the cycle to 0, so doing it
    --                             every frame pins the loop at frame 0, which
    --                             is exactly where the wings used to settle
    --
    -- While flapping, only the first two apply and the loop runs freely.
    local flapping = ply:GetNW2Bool(Flight.PPM2_NW_VAR, false)

    if not ply.ponyrpFlightActivity or not ply.isPlayingPPM2Anim or not flapping then
        ply.ponyrpFlightActivity = true
        ply.isPlayingPPM2Anim = true
        ply:AnimRestartGesture(GESTURE_SLOT_CUSTOM, ACT_GMOD_NOCLIP_LAYER, false)
    end

    -- Ground IK is the other half of what pulls the legs back toward a
    -- standing pose. Off for the entire flight, not merely while flapping.
    if CLIENT then ply:SetIK(false) end

    -- No sequence override: -1 is the base gamemode's own "leave it alone"
    -- sentinel, and leaving it alone is what noclip does.
    return ACT_MP_STAND_IDLE, -1
end)

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
