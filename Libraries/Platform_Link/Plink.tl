-- Platform_Link (c) 2026 Xadaemon available under Apache 2.0 License

-- Platform link is a concise library for data exchange using a compact
-- encoding for data it is agnostic of I/O and it is easy to use and
-- flexible, it allows for RPC between peers, formats and specifics for the
-- encodings the library uses are specified in the documentation of each
-- function that encodes.
-- Relevant functions are:
--  * Plink_Serialize_Table/Array
--  * Plink_Deserialize
--  * Plink_Encode_Command
--
-- If not being used for IPC purposes and just for the SerDes capability you
-- can safely prune the whole IPC region of the lib for a smaller minified
-- end code. The SerDes region is self contained, it owns Escape, Unescape
-- and Has_Separator.

-- #region SerDes

-- Separators, the record fields are delimited by ASCII control codes so that
-- printable bytes are never special and need no escaping.
local US: string = "\31" -- Unit Separator, between a key and its value
local RS: string = "\30" -- Record Separator, after every record
local DC1: string = "\17" -- Device Control 1, leading sigil for a map payload
local DC2: string = "\18" -- Device Control 2, leading sigil for an array payload

--- Escapes the bytes that cannot travel the wire as themselves:
--- '%' becomes %25 and any byte with the high bit set becomes %XX. The high
--- byte pass is what makes non ASCII input survive, Plink_Pack uses bit 7 of
--- every byte as an occupancy flag and would otherwise mangle them.
--- '%' has to go first, otherwise it would escape its own output again.
local function Escape(Data: string): string
    local Out: string = Data:gsub("%%", "%%25")
    Out = Out:gsub("[\128-\255]", function(Byte: string): string
        return string.format("%%%02X", string.byte(Byte))
    end)
    return Out
end

--- Reverses Escape, every %XX pair becomes the byte it denotes. The %x%x in
--- the pattern guarantees the capture is valid hex.
local function Unescape(Data: string): string
    local Out: string = Data:gsub("%%(%x%x)", function(Hex: string): string
        return string.char(tonumber(Hex, 16))
    end)
    return Out
end

--- True when Data holds a separator byte, such data cannot be represented.
local function Has_Separator(Data: string): boolean
    return Data:find("[\30\31]") ~= nil
end

--- Encodes a map of parameters to a string in the form of:
--- <DC1>key<US>value<RS>...keyn<US>valuen<RS> for map shaped tables
--- (key ordering not guaranteed)
--- or
--- <DC2>value<RS>...valuen<RS> for array shaped tables
--- where <DC1> is 0x11, <DC2> is 0x12, <US> is 0x1F and <RS> is 0x1E. The
--- shape marker is a control byte just like the separators, so no printable
--- byte is ever special anywhere in the frame, not even at the very start.
--- Keys and values go through Escape, so every printable byte including ':'
--- and ';' is ordinary data.
--- Returns nil when a key or value contains a separator byte, emitting one
--- would silently corrupt the frame so it is refused instead.
--- NOTE: This format cannot support sub tables, this is a deliberate choice
--- to keep the format simple and avoid recursion.
global function Plink_Serialize_Table(Params: {string: any}): string | nil
    local Output = DC1
    for k, v in pairs(Params) do
        local Key: string = tostring(k)
        local Value: string = tostring(v)
        if Has_Separator(Key) or Has_Separator(Value) then
            return nil
        end
        Output = Output .. Escape(Key) .. US .. Escape(Value) .. RS
    end
    return Output
end

--- See Plink_Serialize_Table for format details
--- does the same but with arrays
global function Plink_Serialize_Array(Params: {any}): string | nil
    local Output = DC2
    for i = 1, #Params do
        local Value: string = tostring(Params[i])
        if Has_Separator(Value) then
            return nil
        end
        Output = Output .. Escape(Value) .. RS
    end
    return Output
end

--- Recover a type from a string
local function Recover_Type(Data: string): number | string | boolean
    if Data == "true" or Data == "false" then
        return Data == "true"
    end
    local Num: number | nil = tonumber(Data)
    if Num then
        return Num
    end
    return Data
end

--- Decodes a string produced by Plink_Serialize_Table or Plink_Serialize_Array,
--- see those functions for details on the format. The leading sigil selects
--- which shape is recovered, anything else yields an empty table.
--- The result is typed as a map rather than an array because either shape can
--- come back, so a deserialized map stays indexable by key. The cost is that
--- '#' does not work on it, count an array shaped result by walking it.
global function Plink_Deserialize(Encoded: string): {any: any}
    local Params: {string | number: any} = {}
    local Sigil: string = Encoded:sub(1, 1)
    -- The sigil is stripped once, here. Inside the body a DC1 or DC2 byte on
    -- a key or a value is just data.
    local Body: string = Encoded:sub(2)
    if Sigil == DC1 then
        for k, v in Body:gmatch("([^\31\30]*)\31([^\30]*)\30") do
            Params[Unescape(k)] = Recover_Type(Unescape(v))
        end
    elseif Sigil == DC2 then
        local i: number = 1
        for v in Body:gmatch("([^\30]*)\30") do
            Params[i] = Recover_Type(Unescape(v))
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
--- characters. Bytes with the high bit set do not survive this, feed it
--- Escape'd data.
--- Max_Len defaults to 255 integers, the most a Plink header can describe,
--- which is 2040 bytes of payload.
--- TODO: Improve the code to unroll r when r is 4 or 8 (if code size allows)
global function Plink_Pack(
    Str: string, Max_Len?: number, Int_Size?: number
): {integer} | nil
    local Encoded: {integer} = {}
    local Current_Sub_Idx: number = 0
    local Current_Int: integer = 0

    if math.ceil(#Str / (Int_Size or 8)) > (Max_Len or 255) then
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

--- Decodes a string encoded by Plink_Pack see the documentation on it for
--- details about the encoding.
global function Plink_Unpack(Encoded: {number}, Int_Size?: number): string
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
        end
    end
    return Decoded
end

global function Plink_Pack_Array(Data: {any}): {integer} | nil
    local Serialized: string | nil = Plink_Serialize_Array(Data)
    if Serialized is nil then
        return nil
    end
    return Plink_Pack(Serialized)
end

global function Plink_Pack_Table(Data: {string: any}): {integer} | nil
    local Serialized: string | nil = Plink_Serialize_Table(Data)
    if Serialized is nil then
        return nil
    end
    return Plink_Pack(Serialized)
end

--- Takes a nilable payload so that it can be chained straight onto
--- Plink_Pack_Array/Table without the caller checking in between.
global function Plink_Unpack_Data(Data: {integer} | nil): {any: any} | nil
    if Data is nil then
        return nil
    end
    return Plink_Deserialize(Plink_Unpack(Data))
end

-- #endregion

-- #region IPC
global record Plink_Command
    Command: number
    Arguments: {any: any}
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
--- The Command word is laid out as follows, no field overlaps another:
---   bits 31..24 signature, 0xAA (10101010)
---   bits 23..8  command number (0..65535)
---   bits 7..0   number of packed integers carried in Encoded_Arguments
--- Byte aligned as [0xAA][command hi][command lo][packed length].
--- NOTE: bit 31 is set, so a peer that reads this word as a signed 32 bit
--- integer sees a negative value, read it as unsigned.
--- Returns nil if the command number does not fit its field, if an argument
--- could not be represented, or if the payload is too large to describe.
global function Plink_Encode_Command(
    Command: number, Arguments: {any: any}
): Plink_Encoded_Command | nil
    -- A command outside the 16 bit field would spill into the signature and
    -- yield a packet that Plink_Is_Valid_Command rejects, refuse it here.
    if Command < 0 or Command > 65535 then
        return nil
    end
    local Serialized_Args: string | nil = nil
    -- test if the Arguments is a map or a list
    -- this check is quite naive
    if Arguments[1] ~= nil then
        Serialized_Args = Plink_Serialize_Array(Arguments)
    else
        Serialized_Args = Plink_Serialize_Table(Arguments)
    end
    if Serialized_Args is nil then
        return nil
    end
    local Encoded_Args = Plink_Pack(Serialized_Args)
    if Encoded_Args is nil then
        return nil
    end
    -- The packed length field is 8 bits wide, a longer payload could not be
    -- described by the header and would corrupt the command number. Plink_Pack
    -- defaults to the same ceiling so this is unreachable today, it is kept as
    -- an invariant guard in case that default moves.
    if #Encoded_Args > 255 then
        return nil
    end
    -- encode the command with the length of its packed payload
    return {
        Command = (2852126720 | (Command << 8)) | #Encoded_Args,
        Encoded_Arguments = Encoded_Args,
    }
end

global function Plink_Is_Valid_Command(Command: number): boolean
    -- Sig = 2852126720 -- 0xAA << 24
    -- Sig_Mask = 4278190080 -- 0xFF << 24
    return Command & 4278190080 == 2852126720
end

--- Get the length of the packed payload of a command, that is how many
--- integers Encoded_Arguments holds. This is not the number of arguments the
--- payload decodes to, the argument count is only known after unpacking.
--- Returns -1 when the command is not a valid Plink packet.
global function Plink_Get_Packed_Len(Command: number): number
    if not Plink_Is_Valid_Command(Command) then
        return -1
    end
    return Command & 255 -- lower 8 bits
end

--- Decodes a command from a packet.
--- Returns nil when the signature does not match, or when the packed length
--- in the header disagrees with the payload actually carried. The latter is
--- what catches most words that pass the one byte signature by chance.
global function Plink_Decode_Command(
    Command_Data: Plink_Encoded_Command
): Plink_Command | nil
    if not Plink_Is_Valid_Command(Command_Data.Command) then
        return nil
    end
    -- command is asserted valid at this point
    local Packed_Len: number = Plink_Get_Packed_Len(Command_Data.Command)
    if Packed_Len ~= #Command_Data.Encoded_Arguments then
        return nil
    end
    -- discard the packed length, mask and read the Command number
    local Command: number = Command_Data.Command >> 8 & 65535
    local Args: {any: any} = Plink_Deserialize(
        Plink_Unpack(Command_Data.Encoded_Arguments)
    )
    return {Command = Command, Arguments = Args}
end

local Plink_Fn_Registry: {number: function} = {}

--- Register a function as the handler for a verb
global function Plink_Register_Command(Command: number, Handler: function)
    Plink_Fn_Registry[Command] = Handler
end

--- Runs a decoded Command, returns false when no handler is registered for it
global function Plink_Run_Command(Command: Plink_Command): boolean
    local Handler = Plink_Fn_Registry[Command.Command]
    if Handler is nil then
        return false
    end
    Handler(Command.Arguments)
    return true
end

-- #endregion
