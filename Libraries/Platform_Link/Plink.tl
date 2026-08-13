-- Platform_Link (c) 2026 Xadaemon available under Apache 2.0 License

-- Platform link is a concise library for data exchange using a compact
-- encoding for data it is agnostic of I/O and it is easy to use and
-- flexible, it allows for RPC between peers, formats and specifics for the
-- encodings the library uses are specified in the documentation of each
-- function that encodes.
-- Relevant functions are:
--  * Plink_Serialize_Table
--  * Plink_Encode_Command
--  * Plink_Encode_Params
--
-- If not being used for IPC purposes and just for the SerDes capability you
-- can safely prune the whole IPC region of the lib for a smaller minified
-- end code.

-- #region SerDes

--- Encodes a map of parameters to a string in the form of:
--- !key:value;...keyn:valuen; for map shaped tables (key ordering not guaranteed)
--- or
--- $value;...valuen; for array shaped tables
--- NOTE: This format cannot support sub tables, this is a deliberate choice
--- to keep the format simple and avoid recursion.
global function Plink_Serialize_Table(Params: {string | number: any}): string
    local Output = "!"
    for k, v in pairs(Params) do
        Output = Output .. tostring(k) .. ":" .. tostring(v) .. ";"
    end
    return Output
end

--- see Plink_Serialize_Table for format details
global function Plink_Serialize_Array(Params: {any}): string
    local Output = "$"
    for i = 1, #Params do
        Output = Output .. tostring(Params[i]) .. ";"
    end
    return Output
end

--- Recover a type from a string
local function Recover_Type(Data: string): number | string | boolean
    if Data == "true" or Data == "false" then
        return Data == "true"
    end
    local Num: number = tonumber(Data)
    if Num then
        return Num
    end
    return Data
end

--- Decodes parameters encoded by Plink_Encode_Params see that function for
--- details on the format.
global function Plink_Deserialize_Table(Encoded: string): {any}
    local Params: {string | number: any} = {}
    if Encoded:sub(1, 1) == "!" then
        for k, v in Encoded:gmatch("([^:]+):([^;]+);") do
            local K_Fixed: string = k
            if k:sub(1, 1) == "!" then
                K_Fixed = k:sub(2)
            end
            Params[K_Fixed] = Recover_Type(v)
        end
    elseif Encoded:sub(1, 1) == "$" then
        local i: number = 1
        for v in Encoded:gmatch("([^;]+);") do
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
global function Plink_Encode_String(
    Str: string, Max_Len?: number, Int_Size?: number
): {number} | nil
    local Encoded: {number} = {}
    local Current_Sub_Idx: number = 0
    local Current_Int: number = 0

    if math.ceil(#Str / (Int_Size or 8)) > (Max_Len or 10) then
        return nil
    end

    local Bytes: {number} = {string.byte(Str, 1, #Str)}
    for i = 1, #Bytes do
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
global function Plink_Decode_String(Encoded: {number}, Int_Size?: number): string | nil
    local Byte_Pos: number = 0
    local Decoded: string = ""
    for i = 1, #Encoded do
        -- split the bytes
        for j = 0, (Int_Size or 8) - 1 do
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

-- #region IPC
global record Plink_Command
    Command: number
    Arguments: {any}
end

global record Plink_Encoded_Command
    Command: number
    Encoded_Arguments: {number}
end

global record Plink_Version_Info
    major: number
    minor: number
    rev: number
end

global function Plink_Version(): Plink_Version_Info
    return {major = 1, minor = 0, rev = 0}
end

--- Encodes a command and its arguments into a packet.
global function Plink_Encode_Command(
    Command: number, Arguments: {any: any}
): Plink_Encoded_Command | nil
    local Serialized_Args: string = ""
    -- test if the Arguments is a map or a list
    -- this check is quite naive
    if Arguments[1] ~= nil then
        Serialized_Args = Plink_Serialize_Array(Arguments)
    else
        Serialized_Args = Plink_Serialize_Table(Arguments)
    end
    local Encoded_Args = Plink_Encode_String(Serialized_Args)
    if Encoded_Args is nil then
        return nil
    end
    -- encode the command with number of expected arguments
    return {
        Command = (336789504 | (Command << 6)) | #Encoded_Args,
        Encoded_Arguments = Encoded_Args,
    }
end

global function Plink_Is_Valid_Command(Command: number): boolean
    -- Sig = 336789504 -- PL << 14
    -- Sig_Mask = 1073725440 -- 0xFFFF << 14
    return Command & 1073725440 == 336789504
end

--- Get the number of arguments for the given command
--- @param Command any
--- @return integer
global function Plink_Get_Arg_Len(Command: number): number
    if not Plink_Is_Valid_Command(Command) then
        return -1
    end
    return Command & 63 -- lower 6 bits
end

--- Decodes a command from a packet.
global function Plink_Decode_Command(
    Command_Data: Plink_Encoded_Command
): Plink_Command | nil
    if not Plink_Is_Valid_Command(Command_Data.Command) then
        return nil
    end
    -- command is asserted valid at this point
    -- discard lowest 6 bits, mask and read the Command number
    local Command: number = Command_Data.Command >> 6 & 1023
    local Args: {any} | number = Plink_Deserialize_Table(
        Plink_Decode_String(Command_Data.Encoded_Arguments)
    )
    if type(Args) == "number" then
        return nil
    end
    return {Command = Command, Arguments = Args}
end

local Plink_Fn_Registry: {number: function} = {}

--- Register a function as the handler for a verb
global function Plink_Register_Command(Command: number, Handler: function)
    Plink_Fn_Registry[Command] = Handler
end

--- Runs a decoded Command
global function Plink_Run_Command(Command: Plink_Command)
    Plink_Fn_Registry[Command.Command](Command.Arguments)
end

-- #endregion
