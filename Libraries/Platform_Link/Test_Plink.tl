require("Plink")

local US: string = "\31"
local RS: string = "\30"

local function Count(Tbl: {any: any}): number
    local N: number = 0
    for _, _ in pairs(Tbl) do
        N = N + 1
    end
    return N
end

local function Test_Strings()
    local str = "Hello World! This is a test"
    local ret = Plink_Pack(str, 40)
    local recv = Plink_Unpack(ret)
    assert(str == recv)
end

local function Test_Command_Encoding_Decoding()
    local enc_cmd = Plink_Encode_Command(10, {30.5, 10, 20})
    if enc_cmd is nil then
        assert(false, "Encoding failed")
    end
    local dec_cmd = Plink_Decode_Command(enc_cmd)
    if dec_cmd is nil then
        assert(false, "Failed to decode")
    else
        assert(dec_cmd.Command == 10,
               "Command should be 10, got" .. dec_cmd.Command)
        assert(dec_cmd.Arguments[1] == 30.5)
        assert(dec_cmd.Arguments[2] == 10)
        assert(dec_cmd.Arguments[3] == 20)

    end
end

--- The command field is 16 bits wide, every value in it must survive a round
--- trip and stay a valid packet, anything wider must be refused.
local function Test_Command_Number_Range()
    for _, cmd in ipairs({0, 1, 255, 256, 1023, 1024, 32768, 65535}) do
        local enc_cmd = Plink_Encode_Command(cmd, {1, 2})
        if enc_cmd is nil then
            assert(false, "Encoding failed for command " .. cmd)
        else
            assert(Plink_Is_Valid_Command(enc_cmd.Command),
                   "Command " .. cmd .. " did not produce a valid packet")
            assert(Plink_Get_Packed_Len(enc_cmd.Command) == #enc_cmd.Encoded_Arguments,
                   "Packed length mismatch for command " .. cmd)
            local dec_cmd = Plink_Decode_Command(enc_cmd)
            if dec_cmd is nil then
                assert(false, "Failed to decode command " .. cmd)
            else
                assert(dec_cmd.Command == cmd,
                       "Expected command " .. cmd .. ", got " .. dec_cmd.Command)
            end
        end
    end
    for _, cmd in ipairs({-1, 65536, 1048576}) do
        assert(Plink_Encode_Command(cmd, {1, 2}) == nil,
               "Out of range command " .. cmd .. " should not encode")
    end
end

--- Every byte a caller can put in a key or value, other than a separator,
--- has to survive the round trip. Counts are asserted as well as contents so
--- that a desynced parser fails loudly instead of passing on the fields that
--- happened to survive.
local function Test_Format_Totality()
    local Cases: {string: any} = {
        semi = "a;b",
        ["k:1"] = "v;2",
        empty = "",
        [""] = "empty key",
        pct = "50%",
        lit = "%C3",
        tab = "a\tb",
        utf = "café",
        cjk = "日本語 café ñ",
        ["!bang"] = "$dollar",
    }
    local Wire = Plink_Serialize_Table(Cases)
    if Wire is nil then
        assert(false, "Serialize_Table refused representable data")
    else
        local Back = Plink_Deserialize(Wire)
        assert(Count(Back) == Count(Cases),
               "Map desync: got " .. Count(Back) ..
               " pairs, want " .. Count(Cases))
        for K, V in pairs(Cases) do
            assert(Back[K] == V,
                   "Map mismatch for [" .. K .. "]: got " ..
                   tostring(Back[K]) .. " want " .. tostring(V))
        end
    end

    local Arr: {any} = {"a;b", "", "c:d", "100%", "café", "$x", "日本語", "a\tb"}
    local A_Wire = Plink_Serialize_Array(Arr)
    if A_Wire is nil then
        assert(false, "Serialize_Array refused representable data")
    else
        local A_Back = Plink_Deserialize(A_Wire)
        assert(Count(A_Back) == #Arr,
               "Array desync: got " .. Count(A_Back) ..
               " elements, want " .. #Arr)
        for i = 1, #Arr do
            assert(A_Back[i] == Arr[i],
                   "Array mismatch at " .. i .. ": got " ..
                   tostring(A_Back[i]) .. " want " .. tostring(Arr[i]))
        end
    end
end

--- Separator bytes cannot be represented, every entry point must refuse them
--- rather than emit a frame that silently truncates on the far side.
local function Test_Separator_Rejection()
    assert(Plink_Serialize_Table({k = "a" .. US .. "b"}) == nil,
           "US in a value should be refused")
    assert(Plink_Serialize_Table({["a" .. RS .. "b"] = "v"}) == nil,
           "RS in a key should be refused")
    assert(Plink_Serialize_Array({"a" .. RS .. "b"}) == nil,
           "RS in an element should be refused")
    assert(Plink_Pack_Table({k = "a" .. US .. "b"}) == nil,
           "Pack_Table should propagate the refusal")
    assert(Plink_Pack_Array({"a" .. US .. "b"}) == nil,
           "Pack_Array should propagate the refusal")
    assert(Plink_Encode_Command(1, {"a" .. RS .. "b"}) == nil,
           "Encode_Command should propagate the refusal")
end

--- The 8 bit packed length field describes at most 255 integers, 2040 bytes.
local function Test_Size_Limits()
    assert(Plink_Pack(string.rep("a", 2040)) ~= nil,
           "A 2040 byte payload should pack")
    assert(Plink_Pack(string.rep("a", 2041)) == nil,
           "A 2041 byte payload should be refused")
    local Big: {any} = {}
    for i = 1, 600 do
        Big[i] = "aaaaaaaa"
    end
    assert(Plink_Encode_Command(1, Big) == nil,
           "A payload past the header ceiling should not encode")
end

--- A refused payload has to travel as nil all the way through the
--- convenience wrappers instead of raising somewhere downstream.
local function Test_Nil_Propagation()
    local Big: {any} = {}
    for i = 1, 600 do
        Big[i] = "aaaaaaaa"
    end
    local Packed = Plink_Pack_Array(Big)
    assert(Packed == nil, "Oversized array should not pack")
    assert(Plink_Unpack_Data(Packed) == nil,
           "Unpack_Data should return nil for a refused payload")
    assert(Plink_Unpack_Data(nil) == nil,
           "Unpack_Data should return nil for an explicit nil")
end

local function Test_Registry()
    local Seen_A: any = nil
    local Seen_B: any = nil
    Plink_Register_Command(7, function(Args: {any})
        Seen_A = Args[1]
        Seen_B = Args[2]
    end)
    assert(Plink_Run_Command({Command = 7, Arguments = {1, 2}}),
           "A registered handler should run")
    assert(Seen_A == 1 and Seen_B == 2,
           "The handler should observe its arguments")
    assert(not Plink_Run_Command({Command = 4242, Arguments = {}}),
           "An unregistered command should return false, not raise")
end

--- The header carries the packed payload length, a packet whose payload
--- disagrees with it is rejected. This is also what catches most random words
--- that pass the one byte signature by chance.
local function Test_Decode_Integrity()
    assert(Plink_Decode_Command({Command = 0, Encoded_Arguments = {}}) == nil,
           "A word without the signature should be refused")
    local Packet = Plink_Encode_Command(5, {1, 2, 3})
    if Packet is nil then
        assert(false, "Encoding failed")
    else
        assert(Plink_Decode_Command(Packet) ~= nil,
               "A sound packet should decode")
        table.remove(Packet.Encoded_Arguments)
        assert(Plink_Decode_Command(Packet) == nil,
               "A payload shorter than the header claims should be refused")
    end
end

Test_Strings()
Test_Command_Encoding_Decoding()
Test_Command_Number_Range()
Test_Format_Totality()
Test_Separator_Rejection()
Test_Size_Limits()
Test_Nil_Propagation()
Test_Registry()
Test_Decode_Integrity()

print("All tests passed")
os.exit(0)
