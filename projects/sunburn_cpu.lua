require("platform_link")
require("common")

--- Waypoint given in an azimuth and time
--- from the last waypoint
--- @class Waypoint
--- @field azimuth number
--- @field time number

local Waypoints = {}
local Cruise_Altitude = 1000
local Last_Error = ""

local function Push_Waypoint(param)
    Waypoints[#Waypoints + 1] = {
        azimuth = param[1],
        time = param[2]
    }
end

local function Pop_Waypoint(_)
    Waypoints[#Waypoints] = nil
end

local function Set_Cruise_Altitude(param)
    Cruise_Altitude = param[1]
end

local function Get_State(_)
    return { verb = 5, parameters = { State } }
end

local function Waypoint_Count(_)
    return { verb = 6, parameters = { #Waypoints } }
end

local function Reset(_)
    Waypoints = {}
    return { verb = 7, parameters = {} }
end

Plink_Register_Command(2, Push_Waypoint)
Plink_Register_Command(3, Pop_Waypoint)
Plink_Register_Command(4, Set_Cruise_Altitude)
Plink_Register_Command(5, Get_State)
Plink_Register_Command(6, Waypoint_Count)
Plink_Register_Command(7, Reset)


Ticks = 0
State = Weapon_State["Idle"]

-- Output 1 to 3 (Number): X, Y and Z position of the block
-- Output 4 to 6 (Number): Euler rotation X, Y and Z of the block
-- Output 7 to 9 (Number): Linear velocity X, Y and Z of the block
-- Output 10 to 12 (Number): Angular velocity X, Y and Z of the block
-- Output 13 (Number): Absolute linear velocity of the block
-- Output 14 (Number): Absolute angular velocity of the block
-- Output 15 (Number): Local Z tilt (pitch)
-- Output 16 (Number): Local X tilt (roll)
-- Output 17 (Number): Compass heading (-0.5 to 0.5)
--- @class IMUState
--- @field x number
--- @field y number
--- @field z number
--- @field pitch number
--- @field roll number
--- @field yaw number
--- @field linear_velocity_x number
--- @field linear_velocity_y number
--- @field linear_velocity_z number
--- @field angular_velocity_x number
--- @field angular_velocity_y number
--- @field angular_velocity_z number
--- @field linear_velocity number
--- @field angular_velocity number
--- @field compass_heading number
--- @field altimeter number

--- Read the IMU state
--- @param offset number The offset to add to the input numbers
--- @return IMUState
function Read_IMU(offset)
    local x = input.getNumber(1 + offset)
    local y = input.getNumber(2 + offset)
    local z = input.getNumber(3 + offset)
    local pitch = input.getNumber(15 + offset)
    local roll = input.getNumber(16 + offset)
    local yaw = input.getNumber(17 + offset)
    local linear_velocity_x = input.getNumber(7 + offset)
    local linear_velocity_y = input.getNumber(8 + offset)
    local linear_velocity_z = input.getNumber(9 + offset)
    local angular_velocity_x = input.getNumber(10 + offset)
    local angular_velocity_y = input.getNumber(11 + offset)
    local angular_velocity_z = input.getNumber(12 + offset)
    local linear_velocity = input.getNumber(13 + offset)
    local angular_velocity = input.getNumber(14 + offset)
    local compass_heading = input.getNumber(17 + offset)
    local altimeter = input.getNumber(18 + offset)
    return {
        x = x,
        y = y,
        z = z,
        pitch = pitch,
        roll = roll,
        yaw = yaw,
        linear_velocity_x = linear_velocity_x,
        linear_velocity_y = linear_velocity_y,
        linear_velocity_z = linear_velocity_z,
        angular_velocity_x = angular_velocity_x,
        angular_velocity_y = angular_velocity_y,
        angular_velocity_z = angular_velocity_z,
        linear_velocity = linear_velocity,
        angular_velocity = angular_velocity,
        compass_heading = compass_heading
    }
end

function onTick()
    Ticks = Ticks + 1

    -- Handle Plink messages
    local Plink_Err = Plink_Dispatch()
    if Plink_Err ~= nil then
        Last_Error = Plink_Err
    end

    local IMU_Frame = Read_IMU(12)
    local Should_Launch = input.getBool(12)
    if #Waypoints > 0 then
        State = Weapon_State["Ready"]
    else
        State = Weapon_State["Idle"]
    end

    if Should_Launch and State ~= Weapon_State["Ready"] then
        -- Signal via Plink that the weapon is not ready
        Plink_Write({ verb = -1, parameters = { 1 } })
    end

    local Request_String = ""
    if Last_Error ~= nil then
        Request_String = Request_String .. "&error=" .. Last_Error
    else
        Request_String = "/?waypointct=" .. #Waypoints .. "&altitude=" .. Cruise_Altitude .. "&state=" .. State
    end
    async.httpGet(8080, Request_String)
end
