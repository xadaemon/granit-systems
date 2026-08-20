# Platform_Link (c) 2026 Xadaemon available under Apache 2.0 License
#
# Python port of Plink's IPC region: command framing on top of
# plink_serdes.py. See docs/Plink.md (repo root) for the wire format.
# If you only need the SerDes capability, import plink_serdes directly and
# skip this module -- the Python equivalent of pruning the IPC region from
# the Lua source.

from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Union

from plink_serdes import (
    PlinkCommandRangeError,
    PlinkDecodeError,
    PlinkSizeError,
    Plink_Deserialize,
    Plink_Pack,
    Plink_Serialize_Array,
    Plink_Serialize_Table,
    Plink_Unpack,
)

# Sig = 0xAA << 24, Sig_Mask = 0xFF << 24
_SIGNATURE = 0xAA000000
_SIGNATURE_MASK = 0xFF000000


def _Normalize32(Value: int) -> int:
    """Masks Value to its unsigned 32-bit pattern, so a header word handed
    in as a signed 32-bit int (e.g. from a C peer -- see the NOTE on
    Plink_Encode_Command) is read the same way regardless of sign."""
    return Value & 0xFFFFFFFF


@dataclass
class Plink_Command:
    Command: int
    Arguments: Dict[Any, Any]


@dataclass
class Plink_Encoded_Command:
    Command: int
    Encoded_Arguments: List[int]


@dataclass
class Plink_Version_Info:
    major: int
    minor: int
    rev: int


def Plink_Version() -> Plink_Version_Info:
    return Plink_Version_Info(major=1, minor=0, rev=0)


def Plink_Encode_Command(
    Command: int, Arguments: Union[Dict[Any, Any], List[Any]]
) -> Plink_Encoded_Command:
    """Encodes a command and its arguments into a packet.
    The Command word is laid out as follows, no field overlaps another:
      bits 31..24 signature, 0xAA (10101010)
      bits 23..8  command number (0..65535)
      bits 7..0   number of packed integers carried in Encoded_Arguments
    Byte aligned as [0xAA][command hi][command lo][packed length].
    NOTE: bit 31 is set, so a peer that reads this word as a signed 32-bit
    integer sees a negative value; read it as unsigned.

    Arguments is array-shaped when given a list, map-shaped otherwise --
    Python's real list/dict distinction replaces the Lua original's naive
    "does index 1 exist" duck-typing check.

    Raises PlinkCommandRangeError when the command number doesn't fit its
    field, PlinkSeparatorError (propagated from the serializer) when an
    argument can't be represented, or PlinkSizeError when the payload is
    too large to describe."""
    if Command < 0 or Command > 65535:
        raise PlinkCommandRangeError(
            f"command number {Command} is outside the 16-bit field (0..65535)"
        )
    if isinstance(Arguments, list):
        Serialized_Args = Plink_Serialize_Array(Arguments)
    else:
        Serialized_Args = Plink_Serialize_Table(Arguments)
    Encoded_Args = Plink_Pack(Serialized_Args)
    # The packed length field is 8 bits wide, a longer payload could not be
    # described by the header and would corrupt the command number.
    # Plink_Pack defaults to the same ceiling so this is unreachable today,
    # it is kept as an invariant guard in case that default moves.
    if len(Encoded_Args) > 255:
        raise PlinkSizeError(
            f"payload packs to {len(Encoded_Args)} integers, which exceeds "
            "the 8-bit packed-length field (255)"
        )
    return Plink_Encoded_Command(
        Command=(_SIGNATURE | (Command << 8)) | len(Encoded_Args),
        Encoded_Arguments=Encoded_Args,
    )


def Plink_Is_Valid_Command(Command: int) -> bool:
    return _Normalize32(Command) & _SIGNATURE_MASK == _SIGNATURE


def Plink_Get_Packed_Len(Command: int) -> int:
    """Get the length of the packed payload of a command, that is how many
    integers Encoded_Arguments holds. This is not the number of arguments
    the payload decodes to, the argument count is only known after
    unpacking. Returns -1 when the command is not a valid Plink packet."""
    if not Plink_Is_Valid_Command(Command):
        return -1
    return _Normalize32(Command) & 255  # lower 8 bits


def Plink_Decode_Command(Command_Data: Plink_Encoded_Command) -> Plink_Command:
    """Decodes a command from a packet.

    Raises PlinkDecodeError when the signature does not match, or when the
    packed length in the header disagrees with the payload actually
    carried -- the latter is what catches most words that pass the
    one-byte signature by chance."""
    Normalized = _Normalize32(Command_Data.Command)
    if not Plink_Is_Valid_Command(Command_Data.Command):
        raise PlinkDecodeError(
            f"signature mismatch: header 0x{Normalized:08X} does not carry "
            f"the 0x{_SIGNATURE:08X} signature (mask 0x{_SIGNATURE_MASK:08X})"
        )
    Packed_Len = Plink_Get_Packed_Len(Command_Data.Command)
    if Packed_Len != len(Command_Data.Encoded_Arguments):
        raise PlinkDecodeError(
            f"packed length mismatch: header claims {Packed_Len} integers, "
            f"payload carries {len(Command_Data.Encoded_Arguments)}"
        )
    Command = (Normalized >> 8) & 65535
    Args = Plink_Deserialize(Plink_Unpack(Command_Data.Encoded_Arguments))
    return Plink_Command(Command=Command, Arguments=Args)


@dataclass
class _Plink_Handler_Info:
    Handler: Callable[[Any], Any]
    Arg_Count: int
    Named: bool


Plink_Fn_Registry = Dict[int, _Plink_Handler_Info]


def Plink_Register_Command(
    Registry: Plink_Fn_Registry,
    Command: int,
    Handler: Callable[[Any], Any],
    Arg_Count: int,
    Named: bool,
) -> None:
    """Register a function as the handler for a verb. Arg_Count and Named
    state the handler's contract: Named selects a map-shaped payload (from
    Plink_Serialize_Table) over an array-shaped one (from
    Plink_Serialize_Array), and Arg_Count is the exact number of entries
    expected. Plink_Run_Command checks Arguments against both before
    calling Handler."""
    Registry[Command] = _Plink_Handler_Info(
        Handler=Handler, Arg_Count=Arg_Count, Named=Named
    )


def Plink_Run_Command(Registry: Plink_Fn_Registry, Command: Plink_Command) -> Any:
    """Runs a decoded Command against its registered handler.

    Returns False, without calling Handler, when no handler is registered
    for the command, or when Arguments doesn't match the handler's declared
    shape (Named) or count (Arg_Count). On a match, returns whatever
    Handler itself returns, unaltered.

    Unlike every other refusal path in this library, neither case raises:
    an unknown verb, and now a mismatched payload, are both routine
    outcomes a peer can trigger just by disagreeing about the interface --
    not malformed data -- so this stays the one place, shared with Lua,
    that reports failure through a return value rather than an exception.

    NOTE: False doubles as the failure sentinel, so a Handler that
    legitimately returns False is indistinguishable from a validation
    failure to the caller -- true of the Lua implementation as well."""
    Info = Registry.get(Command.Command)
    if Info is None:
        return False
    # Same naive array/map heuristic Plink_Encode_Command uses: presence of
    # key 1 marks an array-shaped payload. Skipped when Arg_Count is 0,
    # since an empty dict looks the same either way.
    Has_Index = 1 in Command.Arguments
    if Info.Arg_Count > 0 and Info.Named == Has_Index:
        return False
    if len(Command.Arguments) != Info.Arg_Count:
        return False
    return Info.Handler(Command.Arguments)
