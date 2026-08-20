# Platform_Link (c) 2026 Xadaemon available under Apache 2.0 License
#
# pytest suite for the Python port of Plink. Covers everything
# Test_Plink.tl covers, expressed with pytest idioms (parametrize,
# pytest.raises) rather than transliterated line for line, and adapted to
# this port's raise-on-refusal exception model -- see docs/Plink.md
# (repo root).

import pytest

from plink_ipc import (
    Plink_Command,
    Plink_Decode_Command,
    Plink_Encode_Command,
    Plink_Encoded_Command,
    Plink_Get_Packed_Len,
    Plink_Is_Valid_Command,
    Plink_Register_Command,
    Plink_Run_Command,
)
from plink_serdes import (
    DC1,
    DC2,
    PlinkCommandRangeError,
    PlinkDecodeError,
    PlinkEncodingError,
    PlinkSeparatorError,
    PlinkSizeError,
    Plink_Deserialize,
    Plink_Pack,
    Plink_Pack_Array,
    Plink_Pack_Table,
    Plink_Serialize_Array,
    Plink_Serialize_Table,
    Plink_Unpack,
    Plink_Unpack_Data,
    RS,
    US,
)


def test_strings():
    text = "Hello World! This is a test"
    packed = Plink_Pack(text, 40)
    assert Plink_Unpack(packed) == text


def test_command_encoding_decoding():
    enc = Plink_Encode_Command(10, [30.5, 10, 20])
    dec = Plink_Decode_Command(enc)
    assert dec.Command == 10
    assert dec.Arguments[1] == 30.5
    assert dec.Arguments[2] == 10
    assert dec.Arguments[3] == 20


# The command field is 16 bits wide, every value in it must survive a round
# trip and stay a valid packet, anything wider must be refused.


@pytest.mark.parametrize("cmd", [0, 1, 255, 256, 1023, 1024, 32768, 65535])
def test_command_number_range_valid(cmd):
    enc = Plink_Encode_Command(cmd, [1, 2])
    assert Plink_Is_Valid_Command(enc.Command)
    assert Plink_Get_Packed_Len(enc.Command) == len(enc.Encoded_Arguments)
    dec = Plink_Decode_Command(enc)
    assert dec.Command == cmd


@pytest.mark.parametrize("cmd", [-1, 65536, 1048576])
def test_command_number_range_invalid(cmd):
    with pytest.raises(PlinkCommandRangeError, match=str(cmd)):
        Plink_Encode_Command(cmd, [1, 2])


# Every byte a caller can put in a key or value, other than a separator,
# has to survive the round trip.

_TABLE_CASES = {
    "semi": "a;b",
    "k:1": "v;2",
    "empty": "",
    "": "empty key",
    "pct": "50%",
    "lit": "%C3",
    "tab": "a\tb",
    "utf": "café",
    "cjk": "日本語 café ñ",
    DC1 + "bang": DC2 + "dollar",
}

_ARRAY_CASES = ["a;b", "", "c:d", "100%", "café", DC1 + "x", "日本語", "a\tb"]


def test_format_totality_table():
    wire = Plink_Serialize_Table(_TABLE_CASES)
    back = Plink_Deserialize(wire)
    assert len(back) == len(_TABLE_CASES)
    for k, v in _TABLE_CASES.items():
        assert back[k] == v


def test_format_totality_array():
    wire = Plink_Serialize_Array(_ARRAY_CASES)
    back = Plink_Deserialize(wire)
    assert len(back) == len(_ARRAY_CASES)
    for i, v in enumerate(_ARRAY_CASES, start=1):
        assert back[i] == v


# Separator bytes cannot be represented, every entry point must refuse them
# rather than emit a frame that silently truncates on the far side.


@pytest.mark.parametrize(
    "fn, args",
    [
        (Plink_Serialize_Table, ({"k": "a" + US + "b"},)),
        (Plink_Serialize_Table, ({"a" + RS + "b": "v"},)),
        (Plink_Serialize_Array, (["a" + RS + "b"],)),
        (Plink_Pack_Table, ({"k": "a" + US + "b"},)),
        (Plink_Pack_Array, (["a" + US + "b"],)),
        (Plink_Encode_Command, (1, ["a" + RS + "b"])),
    ],
)
def test_separator_rejection(fn, args):
    with pytest.raises(PlinkSeparatorError):
        fn(*args)


def test_separator_error_message_names_the_key():
    with pytest.raises(PlinkSeparatorError, match="stray"):
        Plink_Serialize_Table({"stray": "a" + US + "b"})


# The 8-bit packed length field describes at most 255 integers, 2040 bytes.


def test_size_limits_pack_ok():
    assert Plink_Pack("a" * 2040) is not None


def test_size_limits_pack_oversize():
    with pytest.raises(PlinkSizeError) as exc_info:
        Plink_Pack("a" * 2041)
    assert "2041" in str(exc_info.value)


def test_size_limits_command_oversize():
    big = ["aaaaaaaa"] * 600
    with pytest.raises(PlinkSizeError) as exc_info:
        Plink_Encode_Command(1, big)
    assert "255" in str(exc_info.value)


# A refused payload has to travel as None through Plink_Unpack_Data's
# passthrough, and every other refusal has to raise instead of returning
# something that looks like success.


def test_refusal_paths():
    big = ["aaaaaaaa"] * 600
    with pytest.raises(PlinkSizeError):
        Plink_Pack_Array(big)
    assert Plink_Unpack_Data(None) is None


def test_registry():
    seen = {}

    def handler(args):
        seen["a"] = args[1]
        seen["b"] = args[2]

    Plink_Register_Command(7, handler)
    assert Plink_Run_Command(Plink_Command(Command=7, Arguments={1: 1, 2: 2})) is True
    assert seen == {"a": 1, "b": 2}
    assert Plink_Run_Command(Plink_Command(Command=4242, Arguments={})) is False


# The header carries the packed payload length, a packet whose payload
# disagrees with it is rejected. This is also what catches most random
# words that pass the one-byte signature by chance.


def test_decode_integrity_bad_signature():
    with pytest.raises(PlinkDecodeError, match="signature"):
        Plink_Decode_Command(Plink_Encoded_Command(Command=0, Encoded_Arguments=[]))


def test_decode_integrity_length_mismatch():
    packet = Plink_Encode_Command(5, [1, 2, 3])
    assert Plink_Decode_Command(packet) is not None
    packet.Encoded_Arguments.pop()
    with pytest.raises(PlinkDecodeError, match="length mismatch"):
        Plink_Decode_Command(packet)


# Python-specific: Plink_Pack bit-matches Lua's signed 64-bit integers so
# packed payloads round-trip identically between a Python and a Lua peer.


def test_pack_signed_wrap():
    # 8 ASCII bytes fill one Int_Size=8 integer; the 8th byte's occupancy
    # flag lands on bit 63, which a fixed-width 64-bit integer reads as
    # negative -- exactly what Lua's integer type does natively.
    text = "abcdefgh"
    packed = Plink_Pack(text)
    assert len(packed) == 1
    assert packed[0] < 0
    assert Plink_Unpack(packed) == text


def test_pack_rejects_non_ascii():
    # Plink_Pack silently mangles non-Escape'd high-bit bytes in the Lua
    # original; this port raises instead, since that's exactly the kind of
    # footgun debug tooling should surface rather than hide.
    with pytest.raises(PlinkEncodingError, match="ASCII"):
        Plink_Pack("café")
