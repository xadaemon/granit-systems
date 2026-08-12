require("platform_link")

function Test_Strings()
    local str = "Hello World! This is a test"
    local ret = Plink_Encode_String(str, 40)
    local recv = Plink_Decode_String(ret)
    assert(str == recv)
end

function Test_Command_Encoding_Decoding()
    local enc_cmd = Plink_Encode_Command(10, { 30.5, 10, 20 })
    local dec_cmd = Plink_Decode_Command(enc_cmd)
    assert(dec_cmd.Command == 10, "Command should be 10, got" .. dec_cmd.Command)
    assert(dec_cmd.Arguments[1] == 30.5)
    assert(dec_cmd.Arguments[2] == 10)
    assert(dec_cmd.Arguments[3] == 20)
end

Test_Strings()
Test_Command_Encoding_Decoding()

print("All tests passed")
