require("Plink")

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

Test_Strings()
Test_Command_Encoding_Decoding()

print("All tests passed")
os.exit(0)
