-- Run from the addon directory: lua tests/takeoff.lua
local function noop() end
local now = 1
IN_JUMP, MOVETYPE_NOCLIP = 2, 8
FCVAR_REPLICATED, FCVAR_NOTIFY, FCVAR_ARCHIVE = 0, 0, 0
bit = { bor = function() return 0 end }
resource = { AddSingleFile = noop }
timer = { Simple = noop }
CreateConVar = function() return { GetBool = function() return false end } end
CreateClientConVar = CreateConVar
GetConVar = function() return nil end
CurTime = function() return now end
IsValid = function(value) return value ~= nil end
isfunction = function(value) return type(value) == "function" end
Vector = function() return { x = 0, y = 0, z = 0, Length = function() return 0 end } end

for _, realm in ipairs({ "server", "client" }) do
    SERVER, CLIENT = realm == "server", realm == "client"
    PonyFlight = nil
    local hooks = {}
    hook = {
        Add = function(event, name, fn)
            hooks[event] = hooks[event] or {}
            hooks[event][name] = fn
        end,
        Remove = function(event, name)
            if hooks[event] then hooks[event][name] = nil end
        end,
        Run = noop
    }
    local ply = { ground = true, allowed = true, nw = {} }
    function ply:OnGround() return self.ground end
    function ply:Alive() return self.allowed end
    function ply:InVehicle() return false end
    function ply:WaterLevel() return 0 end
    function ply:GetMoveType() return 2 end
    function ply:GetPonyData() return { GetRace = function() return "PEGASUS" end } end
    function ply:GetNWBool(key, default)
        if self.nw[key] == nil then return default end
        return self.nw[key]
    end
    function ply:SetNWBool(key, value) self.nw[key] = value end
    ply.GetNW2Bool, ply.SetNW2Bool = ply.GetNWBool, ply.SetNWBool
    ply.SetGravity = noop
    ply.GetVelocity = Vector
    LocalPlayer = function() return ply end
    dofile("lua/ponyflight/sh_flight.lua")
    dofile("lua/ponyflight/" .. (SERVER and "sv_flight.lua" or "cl_flight.lua"))
    local flight = PonyFlight
    local takeoff = hooks.SetupMove[SERVER and "PonyFlight.Takeoff" or "PonyFlight.PredictTakeoff"]
    local landing = hooks.FinishMove[SERVER and "PonyFlight.Upkeep" or "PonyFlight.PredictLanding"]
    local mv = { pressed = false, GetVelocity = Vector, KeyDown = function() return false end }
    function mv:KeyPressed(key) return key == IN_JUMP and self.pressed end
    local function check(ground, pressed, expected, label)
        ply.ground, mv.pressed = ground, pressed
        takeoff(ply, mv)
        assert(flight.VisualFlying(ply) == expected, realm .. ": " .. label)
    end

    check(true, true, false, "ground jump")
    check(false, false, false, "holding jump after leaving ground")
    -- No presentation frame occurs between these movement commands
    ply.ground = true
    landing(ply, mv)
    check(true, true, false, "bunnyhop ground jump")
    check(false, false, false, "bunnyhop airborne without a new press")
    ply.ground = true
    landing(ply, mv)
    check(true, true, false, "jump after touching a ledge")
    check(false, false, false, "walking off a ledge")
    check(false, true, true, "fresh airborne press")
    ply.ground = true
    landing(ply, mv)
    assert(not flight.VisualFlying(ply), realm .. ": landing clears flight")
    check(true, true, false, "immediate ground jump after flight")
    check(false, true, true, "takeoff again before a presentation frame")

    ply.ground = true
    landing(ply, mv)
    ply.allowed = false
    check(false, true, false, "ineligible player")
    ply.allowed = true
    check(false, true, true, "unconfirmed takeoff")
    now = now + 1
    assert(flight.VisualFlying(ply) == SERVER, realm .. ": unconfirmed prediction expires")
    print(realm .. " takeoff checks passed")
end
