--[[
PonyFlight loader.

Four files, listed rather than walked. PonyRP's loader scans a directory
tree because it has tiers and dozens of files; here an explicit list is
shorter than the code that would discover it, and the load order is the
thing that matters most -- sh_flight.lua defines the table and the provider
that the other three read at load time.

Realm tagging follows the same sv_/cl_/sh_ convention as the rest of the
PonyKingdom addons, but is applied by hand below for the same reason.
]]

local SHARED = {
    "ponyflight/sh_flight.lua",
}

local SERVER_FILES = {
    "ponyflight/sv_flight.lua",
}

local CLIENT_FILES = {
    "ponyflight/cl_flight.lua",
    "ponyflight/cl_flightdebug.lua",
}

for _, path in ipairs(SHARED) do
    if SERVER then AddCSLuaFile(path) end
    include(path)
end

if SERVER then
    for _, path in ipairs(CLIENT_FILES) do AddCSLuaFile(path) end
    for _, path in ipairs(SERVER_FILES) do include(path) end
else
    for _, path in ipairs(CLIENT_FILES) do include(path) end
end
