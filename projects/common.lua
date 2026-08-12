--- @enum State
Weapon_State = {
    Idle = -1,
    Ready = 0,
    Launch_Commanded = 1,
    Deploy = 2,
    Boost = 3,
    Cruise = 4,
    Terminal_Guidance = 5,
    -- This is a special state that is used to indicate that the weapon should
    -- be launched immediately it is launched as if in Terminal_Guidance, and
    -- will lock in to the first target it's radar detects. MAKING NO IFF CHECKS.
    Emergency_Launch = 6,
}
