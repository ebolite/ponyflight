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
