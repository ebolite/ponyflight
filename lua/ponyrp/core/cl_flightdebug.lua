--[[
PonyRP flight diagnostics -- client side.

Four seconds of delay, variable, no traceback. That figure is the reason this
file exists: every explanation on the table predicts half a second at worst,
because PPM/2's own SlowUpdate timer (hooks.moon:84, 0.5s on the client)
re-derives the wings from ppm2_fly on its own and would heal anything slower
than that with none of our code involved. Four seconds means ppm2_fly itself
is false for four seconds, or the thing reading it is not running.

So this watches every link in the chain at once and prints only when one of
them changes, with the gap since the last change. Whichever column moves late
is the broken link, and the gaps say how late:

    flying     ponyrp_flying, the server's answer and what we derive from
    ppm2       ppm2_fly, what SelectWingsType and CalcMainActivity both read
    pred       our prediction, and whether its window is still live
    want       what wingsWanted() decided this frame
    wings      the bodygroup actually on the model right now
    expect     what SelectWingsType would return for the current data
    gesture    isPlayingPPM2Anim, set by CalcMainActivity (ponyfly.moon:291)
    move       movetype, for comparison against noclip

Read it against the two known-good references. Noclip flips move and gesture
together with no server involved. Base PPM/2 flight flips ppm2 inside a
predicted SetupMove and kicks the bodygroup through PlayerNoClip.

    ponyrp_flight_watch          watch yourself
    ponyrp_flight_watch <name>   watch somepony else, for the client/server split
    ponyrp_flight_watch_stop
]]

local Flight = PonyRP.Flight

local watching = nil
local previous = nil
local target = nil
local lastAt = 0

local function controllerFor(ply)
    if not isfunction(ply.GetPonyData) then return nil end

    local data = ply:GetPonyData()
    if not data or not isfunction(data.GetBodygroupController) then return nil end

    return data:GetBodygroupController()
end

-- What PPM/2 would put on the model if something asked it right now. The gap
-- between this and the actual bodygroup is the whole question: equal means
-- nothing is refreshing, different means the refresh is running and losing.
local function expectedWings(ply)
    local controller = controllerFor(ply)
    if not controller or not isfunction(controller.SelectWingsType) then return -1 end

    local ok, value = pcall(controller.SelectWingsType, controller)
    return ok and tonumber(value) or -1
end

local function actualWings(ply)
    local controller = controllerFor(ply)
    if not controller then return -1 end

    -- PPM2.BODYGROUP_WINGS is the old-model default (3). The new pony
    -- controller uses 2, so reading the global reports an unrelated group.
    local class = controller.__class
    local group = tonumber(class and class.BODYGROUP_WINGS or controller.BODYGROUP_WINGS)
    if not group or group < 0 then return -1 end

    local ok, value = pcall(ply.GetBodygroup, ply, group)
    return ok and tonumber(value) or -1
end

local function snapshot(ply)
    local predictedAt, predictedFlying = Flight.DebugPrediction()

    return {
        flying = Flight.IsFlying(ply),
        ppm2 = ply:GetNW2Bool(Flight.PPM2_NW_VAR, false),
        pred = predictedAt and predictedFlying or nil,
        live = predictedAt ~= nil,
        want = Flight.DebugWingsWanted(ply),
        wings = actualWings(ply),
        expect = expectedWings(ply),
        gesture = ply.isPlayingPPM2Anim == true,
        move = ply:GetMoveType()
    }
end

local function differs(a, b)
    if not a then return true end

    for _, key in ipairs({ "flying", "ppm2", "pred", "live", "want", "wings", "expect", "gesture", "move" }) do
        if a[key] ~= b[key] then return true end
    end

    return false
end

local function flag(value)
    if value == nil then return "-" end
    return value and "Y" or "n"
end

hook.Add("Think", "PonyRP.Flight.Debug", function()
    if not watching then return end
    if not IsValid(target) then return end

    local shot = snapshot(target)
    if not differs(previous, shot) then return end

    local now = CurTime()
    local gap = previous and (now - lastAt) or 0
    lastAt = now
    previous = shot

    MsgC(Color(150, 220, 255), string.format("[fly %6d +%6.2fs] ", FrameNumber(), gap))
    Msg(string.format(
        "flying %s  ppm2 %s  pred %s%s  want %s  wings %-3d expect %-3d %s gesture %s  move %d\n",
        flag(shot.flying),
        flag(shot.ppm2),
        flag(shot.pred),
        shot.live and "*" or " ",
        flag(shot.want),
        shot.wings,
        shot.expect,
        -- The loud case: PPM/2 already knows the answer and the model has not
        -- been told, which means nothing is calling ApplyRace.
        shot.wings ~= shot.expect and "MISMATCH" or "        ",
        flag(shot.gesture),
        shot.move))
end)

concommand.Add("ponyrp_flight_watch", function(_, _, args)
    target = LocalPlayer()

    if args[1] then
        for _, ply in ipairs(player.GetAll()) do
            if string.find(string.lower(ply:Nick()), string.lower(args[1]), 1, true) then
                target = ply
                break
            end
        end
    end

    watching = true
    previous = nil
    lastAt = CurTime()

    Msg(string.format("[ponyrp flight] watching %s -- transitions only.\n",
        IsValid(target) and target:Nick() or "?"))
    Msg("    pred column: value, then * while the prediction window is live.\n")
    Msg("    MISMATCH means SelectWingsType and the model disagree.\n")
end)

concommand.Add("ponyrp_flight_watch_stop", function()
    watching = nil
    target = nil
    Msg("[ponyrp flight] stopped.\n")
end)
