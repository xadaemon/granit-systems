# Platform_Link (Python)

This is the Python port of [Platform_Link](../Platform_Link/README.md) — a
concise library for data exchange using a compact encoding. It is agnostic
of I/O and designed to be easy to use and flexible. The library enables RPC
between peers.

Formats and specifics for the encodings are specified in the documentation
of each function that encodes, mirroring the Lua original's identifiers and
wire format so a Python peer and a Lua peer can talk to each other.

**Purpose:** unlike the Lua library, this port is not built under a
size-minimizing pipeline — it exists as a debug-tooling foundation. That
shows up in one deliberate divergence from the Lua source: **every refusal
path that returns `nil` in Lua raises a descriptive exception here instead**.
See [Errors](#errors) below.

**Note:** if you only need the SerDes capability, import `plink_serdes`
directly and skip `plink_ipc` — the Python equivalent of pruning the Lua
source's IPC region. `plink_ipc` imports `plink_serdes`; nothing imports
back the other way.

## Relevant Functions

- `Plink_Serialize_Table`/`Plink_Serialize_Array`
- `Plink_Deserialize`
- `Plink_Encode_Command`

---

## SerDes

### Wire format

Records are delimited by ASCII control codes, so no printable byte is ever
special — `:`, `;`, `/` and friends are ordinary data. The shape marker at
the very start of the frame is a control byte too, so this holds for the
entire frame, not just the records within it.

| Code | Byte | Role |
| --- | --- | --- |
| `DC1` | `0x11` | Leading sigil, map-shaped payload |
| `DC2` | `0x12` | Leading sigil, array-shaped payload |
| `US` | `0x1F` | Unit Separator, between a key and its value |
| `RS` | `0x1E` | Record Separator, after every record |

```
map:   <DC1>key<US>value<RS>keyn<US>valuen<RS>
array: <DC2>value<RS>valuen<RS>
```

The leading `DC1`/`DC2` sigil is stripped once by the parser, so a key or
value may itself begin with a `DC1` or `DC2` byte.

### Escaping

Keys and values are percent-escaped on the way out and unescaped on the way
in:

| Input | Becomes |
| --- | --- |
| `%` | `%25` |
| any UTF-8 byte `>= 0x80` | `%XX` |

`%` is escaped first, so `%XX` sequences are never ambiguous. The high-byte
pass is what makes non-ASCII survive: `Plink_Pack` uses bit 7 of every byte
as an occupancy flag and would otherwise mangle it. `Escape`/`Unescape`
operate at the UTF-8 byte level (not per `str` character), so a multi-byte
character like `é` is escaped as two separate `%XX` bytes and correctly
reassembled into one code point on the way back — UTF-8 round-trips, at 3x
size for the non-ASCII bytes.

**The separators themselves are not escaped.** A key or value containing
`0x1F` or `0x1E` cannot be represented; `Plink_Serialize_Table`/`Array`
raise `PlinkSeparatorError` rather than emit a frame that would silently
truncate on the far side.

### Serialization

#### `Plink_Serialize_Table`
Encodes a `Dict[Any, Any]` of parameters to the map form above (key ordering
not guaranteed). Values are stringified with `str()`, except `bool`, which
is spelled `"true"`/`"false"` (lower-case, matching Lua's `tostring` and
what `Recover_Type` expects) rather than Python's `"True"`/`"False"`.

**Note:** this format cannot support nested dicts. This is a deliberate
choice to keep the format simple and avoid recursion.

#### `Plink_Serialize_Array`
See `Plink_Serialize_Table` for format details. Does the same for a `List[Any]`,
emitting the array form.

### Type Recovery

#### `Recover_Type`
Recovers a type from a string. `"true"`/`"false"` become `bool`, anything
`int()`/`float()` accepts becomes a number, everything else stays a `str`.
Note this is lossy: the string `"10"` comes back as the number `10`. This
approximates Lua's `tonumber` — common decimal literals round-trip, but
exotic formats `tonumber` accepts (hex literals, `inf`/`nan`, embedded
underscores) may recover differently here than on the Lua side.

### Deserialization

#### `Plink_Deserialize`
Decodes a string produced by `Plink_Serialize_Table` or
`Plink_Serialize_Array`. See those functions for format details. The
leading sigil selects which shape is recovered; anything else yields an
empty dict.

Always returns `Dict[Any, Any]` — never a `list` — because either shape can
come back and this keeps a deserialized map indexable by key regardless of
which one it was. An array-shaped result is keyed by 1-based integer index,
matching the Lua source; `len()` on the result gives the pair/element count
either way.

### String Encoding

#### `Plink_Pack`
Packs a string consisting of ASCII characters only into a series of
integers. Each byte is encoded in the form:

For each byte `b` at position `i`:
- Let `w` be the width of an integer (`Int_Size`, in bytes)
- Let `j` be the index within an integer (`i % w`)
- Let `r` be the integer being composed
- `r |= (128 | b) << (8 * j)`

This allows indicating which bytes of the integer are occupied by string
characters. Because bit 7 carries that flag, only bytes `0x00`–`0x7F`
survive — feed it `Escape`'d data. If you don't, `Plink_Pack` raises
`PlinkEncodingError` naming the offending character and position, rather
than silently mangling it the way the Lua original does when fed
non-Escape'd input directly.

`Max_Len` defaults to **255 integers = 2040 bytes**, the largest payload a
Plink header can describe. Raises `PlinkSizeError` when the input exceeds
the cap.

**Cross-language interop:** each packed integer is reinterpreted as a
signed 64-bit value — masked to 64 bits and two's-complemented above
`0x7FFFFFFFFFFFFFFF` — exactly as Lua's fixed-width 64-bit integer type
would represent it. Python ints have no fixed width on their own, so
without this step a Python peer and a Lua peer would disagree on the value
of any packed integer whose top byte's occupancy flag lands on bit 63 (i.e.
whenever `Int_Size=8`, the default, and the integer is fully occupied).
`Plink_Unpack` reverses this by masking an incoming integer back to its
unsigned 64-bit pattern before extracting bytes, so it decodes a negative
Python int the same way regardless of whether that int came from this
port's own `Plink_Pack` or from a real Lua peer.

#### `Plink_Unpack`
Decodes a string encoded by `Plink_Pack`. See that function's docstring for
encoding details.

### Convenience Functions

Each wraps a serialize/pack pair. A refusal from either half simply
propagates as whatever exception that half raised — there's no manual
plumbing needed to keep a refusal from becoming a silent success, the way
Lua's `nil` had to be checked and re-returned by hand.

#### `Plink_Pack_Array`
Serializes a list to an integer array using `Plink_Pack` and
`Plink_Serialize_Array`.

#### `Plink_Pack_Table`
Serializes a dict to an integer array using `Plink_Pack` and
`Plink_Serialize_Table`.

#### `Plink_Unpack_Data`
Deserializes integer-encoded data back to its original form using
`Plink_Unpack` and `Plink_Deserialize`.

Takes a **nilable** payload (`Optional[List[int]]`), so it chains straight
onto `Plink_Pack_Array`/`Plink_Pack_Table` without a check in between. This
is the one refusal-shaped path that deliberately still returns `None`
rather than raising: `None` in means "nothing to decode", not "decoding
failed", so `None` out is the correct, expected result — not a refusal.

```python
Data = Plink_Unpack_Data(Plink_Pack_Table(Params))
if Data is None:
    # there was nothing to unpack (Plink_Pack_Table wasn't called, or its
    # result was never produced) -- this is not the same as a refusal,
    # which would have raised instead.
    ...
```

---

## IPC

### Version

#### `Plink_Version`
Returns version information as `Plink_Version_Info` with fields: `major`,
`minor`, `rev`.

### Packet header

A command is one integer with three non-overlapping fields, byte-aligned as
`[0xAA][command hi][command lo][packed length]`:

```
 31    24 23           8 7      0
+--------+--------------+--------+
|  0xAA  | command      | packed |
|  sig   | number       | length |
+--------+--------------+--------+
   8 bits    16 bits      8 bits
```

| Field | Bits | Range | Constant |
| --- | --- | --- | --- |
| Signature | 31..24 | `0xAA` (`10101010`) | `0xAA000000`, mask `0xFF000000` |
| Command number | 23..8 | `0`..`65535` | `<< 8`, `& 65535` |
| Packed length | 7..0 | `0`..`255` (2040 bytes) | `& 255` |

The packed length counts **integers in `Encoded_Arguments`**, not decoded
arguments.

**Portability:** `0xAA000000` sets bit 31, so this word is negative when
read as a signed 32-bit integer. A C or embedded peer must read it as
`uint32_t`, or compare with masking. Because a raw header word can arrive
from such a peer as a signed 32-bit value, `Plink_Is_Valid_Command`,
`Plink_Get_Packed_Len`, and `Plink_Decode_Command` all mask their `Command`
input to its unsigned 32-bit pattern before testing it, so either
representation is accepted.

**Framing:** a one-byte signature false-accepts a random word with
probability 1/256. `Plink_Decode_Command` also checks the header's packed
length against the payload actually carried, which rejects most of those.
The library is I/O agnostic, so real framing remains the caller's job.

### Command Encoding

#### `Plink_Encode_Command`
Encodes a command and its arguments into a packet. `Arguments` is
array-shaped when given a `list`, map-shaped otherwise (`dict`) — Python's
real `list`/`dict` distinction replaces the Lua original's naive "does
index 1 exist" duck-typing check. Internally uses `Plink_Pack` for argument
serialization.

Raises:
- `PlinkCommandRangeError` when the command number is outside `0`..`65535`,
- `PlinkSeparatorError` (propagated from the serializer) when a key or
  value holds a separator byte,
- `PlinkSizeError` when the payload is too large for the header to
  describe.

#### `Plink_Is_Valid_Command`
Checks if a command is valid by matching the signature field against
`0xFF000000`.

#### `Plink_Get_Packed_Len`
Get the length of the packed payload of a command, that is how many
integers `Encoded_Arguments` holds. This is *not* the number of arguments
the payload decodes to — the argument count is only known after unpacking.

**Returns:** the packed length, or `-1` when the command is not a valid
Plink packet.

#### `Plink_Decode_Command`
Decodes a command from a packet. Internally uses `Plink_Unpack` for
argument deserialization.

Raises `PlinkDecodeError` when the signature does not match, or when the
header's packed length disagrees with the payload actually carried — the
message names which of the two happened, and the values involved.

### Command Registration

#### `Plink_Register_Command`
Register a function as the handler for a verb.

#### `Plink_Run_Command`
Runs a decoded `Plink_Command`. Returns `bool`: `False` when no handler is
registered for that command number. This one is deliberately **not** part
of the raise-on-refusal model — an unregistered command from a peer is a
routine, expected outcome (see [Errors](#errors)), not a malformed payload.

---

## Errors

Every refusal path that returns `nil` in the Lua library raises an
exception here instead, all deriving from `PlinkError`:

| Lua behavior | Python behavior |
| --- | --- |
| `Serialize_Table`/`Array` return `nil` on a separator byte | raises `PlinkSeparatorError` naming the key/index and the offending value |
| `Plink_Pack` returns `nil` when the payload exceeds `Max_Len` | raises `PlinkSizeError` with the computed length and the ceiling |
| `Plink_Pack` given non-Escape'd (non-ASCII) input — silently mangled in Lua | raises `PlinkEncodingError` naming the character and position (Python-only check) |
| `Plink_Encode_Command` returns `nil` for a command outside `0..65535` | raises `PlinkCommandRangeError` with the value given |
| `Plink_Encode_Command` returns `nil` when the packed payload exceeds 255 integers | raises `PlinkSizeError` with the actual count |
| `Plink_Decode_Command` returns `nil` on a signature mismatch | raises `PlinkDecodeError` naming the header word and expected signature |
| `Plink_Decode_Command` returns `nil` on a packed-length mismatch | raises `PlinkDecodeError` naming the claimed vs. actual length |

Two paths are **not** converted to exceptions, because they were never
refusals to begin with — see their sections above for why:
`Plink_Unpack_Data(None)` still returns `None`, and `Plink_Run_Command`
still returns `bool`.

This trade — exceptions with actionable messages instead of Lua's
size-minimizing `nil`-propagation — is deliberate: this port exists to be a
debugging aid, not an embedded, minified artifact, so it's worth the extra
lines to say *why* something didn't decode instead of just saying it
didn't.

---

## Data Types

### Records (`@dataclass`)

- `Plink_Command`: `Command: int`, `Arguments: Dict[Any, Any]`
- `Plink_Encoded_Command`: `Command: int`, `Encoded_Arguments: List[int]`
- `Plink_Version_Info`: `major: int`, `minor: int`, `rev: int`

---

## Testing

`test_plink.py` is a `pytest` suite (`pip install pytest` or `uv run --with
pytest -- pytest ...`) covering the same ground as the Lua library's
`Test_Plink.tl`, plus a couple of Python-specific cases for the signed
64-bit packing behavior and for `Plink_Pack`'s ASCII-input check. Run it
from the repo root:

```sh
pytest Libraries/Platform_Link_Py
```
