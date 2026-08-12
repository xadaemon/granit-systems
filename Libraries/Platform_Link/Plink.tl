-- Platform_Link (c) 2026 Xadaemon available under Apache 2.0 License

-- Platform link is a concise library for data exchange using a compact
-- encoding for data it is agnostic of I/O and it is easy to use and
-- flexible, it allows for RPC between peers, formats and specifics for the
-- encodings the library uses are specified in the documentation of each
-- function that encodes.
-- Relevant ones are:
--  * Plink_Serialize_Table
--  * Plink_Encode_Command
--  * Plink_Encode_Params

local tl = require("tl")

-- #region Types

record Plink_Command
    Command: number
    Arguments: {any}
end

record Plink_Encoded_Command
    Command: number
    Encoded_Arguments: {number}
end

record Plink_Version_Info
    major: number
    minor: number
    rev: number
end

-- #endregion

-- @type table<number, function>
local Plink_Fn_Registry: {number: function} = {}

function Plink_Version(): Plink_Version_Info
    return { major = 1, minor = 0, rev = 0 }
end

--- Register a function as the handler for a verb
--- @param Command number
--- @param Handler function
function Plink_Register_Command(Command: number, Handler: function)
    Plink_Fn_Registry[Command] = Handler
end

--- Runs a decoded Command
--- @param Command Plink_Command
function Plink_Run_Command(Command: Plink_Command)
    Plink_Fn_Registry[Command.Command](Command.Arguments)
end

-- #region Serdes

--- Encodes a map of parameters to a string in the form of:
--- !key:value;...keyn:valuen;
--- or
--- $value;...valuen;
--- NOTE: This format cannot support sub tables, this is a deliberate choice
--- to keep the format simple and avoid recursion.
--- @param Params table
--- @param Encode_Map boolean?
--- @return string
function Plink_Serialize_Table(Params: {any}, Encode_Map: boolean?): string
    local Output: string = ""
    if Encode_Map then
        Output = "!"
        for k: string, v: any in pairs(Params) do
            Output = Output .. k .. ":" .. tostring(v) .. ";"
        end
    else
        Output = "$"
        for i: number = 1, #Params do
            Output = Output .. tostring(Params[i]) .. ";"
        end
    end
    return Output
end

--- Recover a type from a string
--- @param Data string
--- @return number | string | boolean
local function Recover_Type(Data: string): number | string | boolean
    if Data == "true" or Data == "false" then
        return Data == "true"
    end
    local Num: number? = tonumber(Data)
    if Num then
        return Num
    end
    return Data
end

--- Decodes parameters encoded by Plink_Encode_Params see that function for
--- details on the format.
--- @param Encoded string
function Plink_Deserialize_Table(Encoded: string): {any}
    local Params: {any} = {}
    if Encoded:sub(1, 1) == "!" then
        for k: string, v: string in Encoded:gmatch("([^:]+):([^;]+);") do
            local K_Fixed: string = k
            if k:sub(1, 1) == "!" then
                K_Fixed = k:sub(2)
            end
            Params[K_Fixed] = Recover_Type(v)
        end
    elseif Encoded:sub(1, 1) == "$" then
        local i: number = 1
        for v: string in Encoded:gmatch("([^;]+);") do
            local V_Fixed: string = v
            if v:sub(1, 1) == "$" then
                V_Fixed = v:sub(2)
            end
            Params[i] = Recover_Type(V_Fixed)
            i = i + 1
        end
    end
    return Params
end

--- Packs a string consisting of ASCII characters only into a series
--- of integers ecoded in the form of per character each byte is given by the
--- formula:
--- let b be the byte at position i
--- let w be the width of an integer
--- let j be the index within an integer (j % w)
--- let r be the integer being composed
--- r := r | (128 | b) << (j * 8)
--- this allows to indicate which bytes of the integer are ocupied by string
--- characters.
--- TODO: Improve the code to unroll r when r is 4 or 8 (if code size allows)
--- @param Str string
--- @param Max_Len integer?
--- @param Int_Size integer? defaults to 4 byte wide ints
--- @return {number} | number
function Plink_Encode_String(Str: string, Max_Len: number?, Int_Size: number?): {number} | number
    local Encoded: {number} = {}
    local Current_Sub_Idx: number = 0
    local Current_Int: number = 0

    if math.ceil(#Str / (Int_Size or 8)) > (Max_Len or 10) then
        return math.ceil(#Str / (Int_Size or 8))
    end

    local Bytes: {number} = { string.byte(Str, 1, #Str) }
    for i: number = 1, #Bytes do
        Current_Int = Current_Int | (Bytes[i] | 128) << (8 * Current_Sub_Idx)
        if Current_Sub_Idx == (Int_Size or 8) - 1 then
            table.insert(Encoded, Current_Int)
            Current_Sub_Idx = 0
            Current_Int = 0
        else
            Current_Sub_Idx = Current_Sub_Idx + 1
        end
    end
    if Current_Int ~= 0 then
        table.insert(Encoded, Current_Int)
    end
    return Encoded
end

--- Decodes a string encoded by Encode_String see the documentation on it for
--- details about the encoding.
--- @param Encoded table<number>
--- @param Int_Size integer?
--- @return string | nil
function Plink_Decode_String(Encoded: {number}, Int_Size: number?): string | nil
    local Byte_Pos: number = 0
    local Decoded: string = ""
    for i: number = 1, #Encoded do
        -- split the bytes
        for j: number = 0, (Int_Size or 8) - 1 do
            local Byte_At: number = Encoded[i] >> (j * 8) & 255
            -- Stop processing the integer as soon as a byte with MSB unset is
            -- encountered
            if Byte_At & 128 ~= 0 then
                Decoded = Decoded .. string.char(Byte_At & 127)
            else
                break
            end
            Byte_Pos = Byte_Pos + 1
        end
    end
    return Decoded
end

-- #endregion

-- #region Packet_Encoding

--- Encodes a command and its arguments into a packet.
--- @param Command integer
--- @param Arguments table<string, any> | [any]
--- @return Plink_Encoded_Command | integer
function Plink_Encode_Command(Command: number, Arguments: {any}): Plink_Encoded_Command | number
    local Serialized_Args: string = ""
    -- test if the Arguments is a map or a list
    -- this check is quite naive
    if Arguments[1] ~= nil then
        Serialized_Args = Plink_Serialize_Table(Arguments)
    else
        Serialized_Args = Plink_Serialize_Table(Arguments, true)
    end
    local Encoded_Args: {number} | number = Plink_Encode_String(Serialized_Args)
    if type(Encoded_Args) == "number" then
        return -1
    end
    -- encode the command with number of expected arguments
    return {
        Command = (336789504 | (Command << 6)) | #Encoded_Args,
        Encoded_Arguments = Encoded_Args
    }
end

function Plink_Is_Valid_Command(Command: number): boolean
    -- Sig = 336789504 -- PL << 14
    -- Sig_Mask = 1073725440 -- 0xFFFF << 14
    return Command & 1073725440 == 336789504
end

--- Get the number of arguments for the given command
--- @param Command any
--- @return integer
function Plink_Get_Arg_Len(Command: number): number
    if not Plink_Is_Valid_Command(Command) then
        return -1
    end
    return Command & 63 -- lower 6 bits
end

--- Decodes a command from a packet.
--- @param Command_Data Plink_Encoded_Command
--- @return integer | Plink_Command
function Plink_Decode_Command(Command_Data: Plink_Encoded_Command): number | Plink_Command
    if not Plink_Is_Valid_Command(Command_Data.Command) then
        return -1
    end
    -- command is asserted valid at this point
    -- discard lowest 6 bits, mask and read the Command number
    local Command: number = Command_Data.Command >> 6 & 1023
    local Args: {any} | number = Plink_Deserialize_Table(Plink_Decode_String(Command_Data.Encoded_Arguments))
    if type(Args) == "number" then
        return -1
    end
    return { Command = Command, Arguments = Args }
end

-- #endregion
