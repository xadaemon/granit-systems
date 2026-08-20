# Platform_Link (c) 2026 Xadaemon available under Apache 2.0 License
#
# Python port of Plink's SerDes region. See docs/Plink.md (repo root) for
# the wire format. This module is self contained: it owns every exception
# type the rest of the library raises, and plink_ipc.py is the only other
# module that imports it. If you only need the SerDes capability, importing
# this module alone (skipping plink_ipc) is the Python equivalent of pruning
# the IPC region from the Lua source.
#
# Unlike the Lua original, refusal paths here raise instead of returning
# nil/None -- this port exists as a debugging aid, not a size-minimized embed
# target, and a raised exception naming the offending value is more useful
# than a bare None when you're trying to figure out why a peer's packet
# won't decode.

import math
import re
from typing import Any, Dict, List, Optional, Union

# Separators: record fields are delimited by ASCII control codes so that
# printable bytes are never special and need no escaping. The leading shape
# sigil is a control byte too, so this holds for the whole frame, not just
# the records within it.
US = "\x1f"  # Unit Separator, between a key and its value
RS = "\x1e"  # Record Separator, after every record
DC1 = "\x11"  # Device Control 1, leading sigil for a map-shaped payload
DC2 = "\x12"  # Device Control 2, leading sigil for an array-shaped payload

_SEPARATOR_RE = re.compile("[\x1e\x1f]")
_ESCAPE_BYTES_RE = re.compile(rb"%([0-9A-Fa-f]{2})")
_HIGH_BYTE_RE = re.compile(rb"[\x80-\xff]")
_MAP_ENTRY_RE = re.compile(r"([^\x1e\x1f]*)\x1f([^\x1e]*)\x1e")
_ARRAY_ENTRY_RE = re.compile(r"([^\x1e]*)\x1e")


class PlinkError(Exception):
    """Base class for every error this library raises."""


class PlinkSeparatorError(PlinkError):
    """A key, value, or element contains a US/RS separator byte."""


class PlinkSizeError(PlinkError):
    """A payload exceeds a length ceiling the wire format can describe."""


class PlinkCommandRangeError(PlinkError):
    """A command number falls outside the 16-bit command field."""


class PlinkDecodeError(PlinkError):
    """A packet's header signature or packed length doesn't check out."""


class PlinkEncodingError(PlinkError):
    """Plink_Pack was given data that wasn't Escape'd first."""


def _Plink_Str(Value: Any) -> str:
    """tostring() with Lua's lower-case boolean spelling, so Recover_Type
    (which checks for literal "true"/"false") round-trips Python bools."""
    if isinstance(Value, bool):
        return "true" if Value else "false"
    return str(Value)


def Escape(Data: str) -> str:
    """Escapes the bytes that cannot travel the wire as themselves: '%'
    becomes %25 and any UTF-8 byte with the high bit set becomes %XX. The
    high-byte pass is what makes non-ASCII input survive: Plink_Pack uses
    bit 7 of every byte as an occupancy flag and would otherwise mangle
    them. '%' goes first, otherwise it would escape its own output again."""
    Raw = Data.encode("utf-8")
    Raw = Raw.replace(b"%", b"%25")
    Raw = _HIGH_BYTE_RE.sub(lambda m: b"%%%02X" % m.group(0)[0], Raw)
    return Raw.decode("ascii")


def Unescape(Data: str) -> str:
    """Reverses Escape. Works at the byte level (not per character) so that
    a multi-byte UTF-8 sequence that was escaped one byte at a time decodes
    back to a single correct code point instead of several mangled ones."""
    Raw = Data.encode("ascii")
    Raw = _ESCAPE_BYTES_RE.sub(lambda m: bytes([int(m.group(1), 16)]), Raw)
    return Raw.decode("utf-8")


def Has_Separator(Data: str) -> bool:
    """True when Data holds a separator byte; such data cannot be represented."""
    return _SEPARATOR_RE.search(Data) is not None


def Plink_Serialize_Table(Params: Dict[Any, Any]) -> str:
    """Encodes a map of parameters to a string in the form of:
    <DC1>key<US>value<RS>...keyn<US>valuen<RS> (key ordering not
    guaranteed). The leading DC1 sigil is a control byte just like the
    separators, so no printable byte is ever special anywhere in the
    frame, not even at the very start. Keys and values go through Escape,
    so every printable byte including ':' and ';' is ordinary data.

    Raises PlinkSeparatorError when a key or value contains a separator
    byte -- emitting one would silently corrupt the frame, so it's refused
    instead.

    NOTE: this format cannot support sub-tables/nested dicts, this is a
    deliberate choice to keep the format simple and avoid recursion."""
    Output = DC1
    for k, v in Params.items():
        Key = _Plink_Str(k)
        Value = _Plink_Str(v)
        if Has_Separator(Key):
            raise PlinkSeparatorError(
                f"key {Key!r} contains a US/RS separator byte, cannot serialize"
            )
        if Has_Separator(Value):
            raise PlinkSeparatorError(
                f"value {Value!r} for key {Key!r} contains a US/RS separator "
                "byte, cannot serialize"
            )
        Output += Escape(Key) + US + Escape(Value) + RS
    return Output


def Plink_Serialize_Array(Params: List[Any]) -> str:
    """See Plink_Serialize_Table for format details. Does the same but for
    a list, emitting <DC2>value<RS>...valuen<RS>. Raises PlinkSeparatorError
    under the same condition."""
    Output = DC2
    for i, v in enumerate(Params, start=1):
        Value = _Plink_Str(v)
        if Has_Separator(Value):
            raise PlinkSeparatorError(
                f"element {i} ({Value!r}) contains a US/RS separator byte, "
                "cannot serialize"
            )
        Output += Escape(Value) + RS
    return Output


def Recover_Type(Data: str) -> Union[bool, int, float, str]:
    """Recover a type from a string. This approximates Lua's tonumber:
    common decimal int/float literals round-trip, but exotic formats
    tonumber accepts (hex literals, inf/nan, embedded underscores) may
    recover differently here than on the Lua side."""
    if Data == "true":
        return True
    if Data == "false":
        return False
    try:
        return int(Data)
    except ValueError:
        pass
    try:
        return float(Data)
    except ValueError:
        pass
    return Data


def Plink_Deserialize(Encoded: str) -> Dict[Any, Any]:
    """Decodes a string produced by Plink_Serialize_Table or
    Plink_Serialize_Array. The leading sigil selects which shape is
    recovered; anything else yields an empty dict.

    The result is always a dict (never a list), because either shape can
    come back and this keeps a deserialized map indexable by key. An
    array-shaped result is keyed by 1-based integer index, matching the
    Lua source."""
    Params: Dict[Any, Any] = {}
    if not Encoded:
        return Params
    Sigil = Encoded[0]
    Body = Encoded[1:]
    if Sigil == DC1:
        for m in _MAP_ENTRY_RE.finditer(Body):
            Params[Unescape(m.group(1))] = Recover_Type(Unescape(m.group(2)))
    elif Sigil == DC2:
        for i, m in enumerate(_ARRAY_ENTRY_RE.finditer(Body), start=1):
            Params[i] = Recover_Type(Unescape(m.group(1)))
    return Params


def _To_Signed64(Value: int) -> int:
    Value &= 0xFFFFFFFFFFFFFFFF
    if Value >= 0x8000000000000000:
        Value -= 0x10000000000000000
    return Value


def _To_Unsigned64(Value: int) -> int:
    return Value & 0xFFFFFFFFFFFFFFFF


def Plink_Pack(
    Str: str, Max_Len: Optional[int] = None, Int_Size: Optional[int] = None
) -> List[int]:
    """Packs a string consisting of ASCII characters only into a series of
    integers, encoded so that each byte b at position i within an integer
    of width w contributes: r |= (128 | b) << (8 * (i % w)). This allows
    indicating which bytes of the integer are occupied by string
    characters. Bytes with the high bit set do not survive this -- feed it
    Escape'd data, and Plink_Pack raises PlinkEncodingError if it isn't.

    Each packed integer is reinterpreted as a signed 64-bit value (masked
    and two's-complemented as Lua's fixed-width integers are), so a Python
    peer and a Lua peer agree bit-for-bit on Encoded_Arguments, including
    values that go negative because the top byte's occupancy flag lands on
    bit 63.

    Max_Len defaults to 255 integers, the most a Plink header can describe,
    which is 2040 bytes of payload at the default Int_Size=8. Raises
    PlinkSizeError when the payload exceeds that ceiling."""
    Max_Len = 255 if Max_Len is None else Max_Len
    Int_Size = 8 if Int_Size is None else Int_Size

    try:
        Bytes = Str.encode("ascii")
    except UnicodeEncodeError as e:
        raise PlinkEncodingError(
            f"Plink_Pack requires ASCII input (Escape'd data); found a "
            f"non-ASCII character at position {e.start}: {Str[e.start]!r}. "
            "Run the string through Escape() first."
        ) from e

    Packed_Len = math.ceil(len(Bytes) / Int_Size)
    if Packed_Len > Max_Len:
        raise PlinkSizeError(
            f"payload of {len(Bytes)} bytes needs {Packed_Len} integers at "
            f"Int_Size={Int_Size}, which exceeds Max_Len={Max_Len}"
        )

    Encoded: List[int] = []
    Current_Sub_Idx = 0
    Current_Int = 0
    for b in Bytes:
        Current_Int |= (b | 128) << (8 * Current_Sub_Idx)
        if Current_Sub_Idx == Int_Size - 1:
            Encoded.append(_To_Signed64(Current_Int))
            Current_Sub_Idx = 0
            Current_Int = 0
        else:
            Current_Sub_Idx += 1
    if Current_Int != 0:
        Encoded.append(_To_Signed64(Current_Int))
    return Encoded


def Plink_Unpack(Encoded: List[int], Int_Size: Optional[int] = None) -> str:
    """Decodes a string encoded by Plink_Pack, see that function's
    docstring for details. Each integer is treated as an unsigned 64-bit
    bit pattern before extracting bytes, so a negative Python int (produced
    by Plink_Pack, or received from a Lua peer) decodes identically to
    Lua's unsigned right-shift semantics."""
    Int_Size = 8 if Int_Size is None else Int_Size
    Decoded = bytearray()
    for Word in Encoded:
        Word = _To_Unsigned64(Word)
        for j in range(Int_Size):
            Byte_At = (Word >> (8 * j)) & 255
            # Stop processing the integer as soon as a byte with MSB unset
            # is encountered.
            if Byte_At & 128:
                Decoded.append(Byte_At & 127)
            else:
                break
    return Decoded.decode("ascii")


def Plink_Pack_Array(Data: List[Any]) -> List[int]:
    """Serializes a list to an integer array using Plink_Pack and
    Plink_Serialize_Array. Propagates either function's exceptions."""
    return Plink_Pack(Plink_Serialize_Array(Data))


def Plink_Pack_Table(Data: Dict[Any, Any]) -> List[int]:
    """Serializes a dict to an integer array using Plink_Pack and
    Plink_Serialize_Table. Propagates either function's exceptions."""
    return Plink_Pack(Plink_Serialize_Table(Data))


def Plink_Unpack_Data(Data: Optional[List[int]]) -> Optional[Dict[Any, Any]]:
    """Deserializes integer-encoded data back to its original form using
    Plink_Unpack and Plink_Deserialize.

    Takes a nilable payload -- an explicit None passes straight through as
    None -- so it chains onto Plink_Pack_Array/Table's result without the
    caller checking in between. This is the one refusal-shaped path that
    deliberately stays None rather than raising: None here means "nothing
    to decode", not "decoding failed"."""
    if Data is None:
        return None
    return Plink_Deserialize(Plink_Unpack(Data))
