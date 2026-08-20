# Plink (Platform_Link)

Plink is a concise library for data exchange using a compact encoding. It is
agnostic of I/O and designed to be easy to use and flexible. The library
enables RPC between peers.

Two implementations live in this repo and share one wire format, so a peer
running either can talk to a peer running the other:

- **Lua** (Teal) — [`Libraries/Platform_Link/`](../Libraries/Platform_Link/),
  built under a size-minimizing pipeline. See [Lua](#lua).
- **Python** — [`Libraries/Platform_Link_Py/`](../Libraries/Platform_Link_Py/),
  a debug-tooling-focused port. See [Python](#python).

This document specifies the protocol once, in [Protocol](#protocol), and
covers only what's genuinely different about each implementation in its own
section — calling convention, pruning mechanics, data type representation,
and how to run its tests.

---

## Protocol

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
| any byte `>= 0x80` | `%XX` |

`%` is escaped first, so `%XX` sequences are never ambiguous. The high-byte
pass is what makes non-ASCII survive: `Plink_Pack` (below) uses bit 7 of
every byte as an occupancy flag and would otherwise mangle it. Escaping and
unescaping happen at the byte level, so a multi-byte UTF-8 character like
`é` is escaped as two separate `%XX` bytes and correctly reassembled into
one code point on the way back — UTF-8 round-trips, at 3x size for the
non-ASCII bytes.

**The separators themselves are not escaped.** A key or value containing
`0x1F` or `0x1E` cannot be represented; serializing one is refused rather
than emitting a frame that would silently truncate on the far side.

### Serialization

#### `Plink_Serialize_Table`
Encodes a map of parameters into the map form above (key ordering not
guaranteed). Keys and values go through Escape, so every printable byte
including `:` and `;` is ordinary data. Refused when any key or value holds
a separator byte.

**Note:** this format cannot support sub-tables/nested maps. This is a
deliberate choice to keep the format simple and avoid recursion.

#### `Plink_Serialize_Array`
See `Plink_Serialize_Table` for format details. Does the same for an array,
emitting the array form above. Refused under the same condition.

### Type Recovery

#### `Recover_Type`
Recovers a type from a string. `"true"`/`"false"` become booleans, anything
the host language's numeric parser accepts becomes a number, everything
else stays a string. Note this is lossy: the string `"10"` comes back as
the number `10`.

### Deserialization

#### `Plink_Deserialize`
Decodes a string produced by `Plink_Serialize_Table` or
`Plink_Serialize_Array`. The leading sigil selects which shape is
recovered; anything else yields an empty result.

Always returns a map — never a bare array — because either shape can come
back and this keeps a deserialized result indexable by key regardless of
which one it was. An array-shaped result is keyed by 1-based integer index.

### String Packing

#### `Plink_Pack`
Packs a string consisting of ASCII characters only into a series of fixed-
width integers. Each byte is encoded in the form:

For each byte `b` at position `i`:
- Let `w` be the width of an integer (`Int_Size`, in bytes)
- Let `j` be the index within an integer (`i % w`)
- Let `r` be the integer being composed
- `r |= (128 | b) << (8 * j)`

This allows indicating which bytes of the integer are occupied by string
characters. Because bit 7 carries that flag, only bytes `0x00`–`0x7F`
survive — feed it `Escape`'d data.

`Max_Len` defaults to **255 integers = 2040 bytes**, the largest payload a
Plink header can describe. Refused when the input exceeds the cap.

**Cross-language interop:** each packed integer is a fixed `Int_Size*8`-bit
value, and once its top bit is set (which happens whenever `Int_Size=8`,
the default, and the integer is fully occupied — the last byte's occupancy
flag lands on bit 63), a peer reading it as a native fixed-width integer
type must interpret it with the same signedness a 64-bit two's-complement
integer would carry. Any two implementations that disagree here will
disagree on the wire value of that integer. See [Python](#python) for how a
language without a native fixed-width integer type reproduces this bit
pattern to stay compatible.

#### `Plink_Unpack`
Decodes a string encoded by `Plink_Pack`. See that function's entry above
for encoding details.

### Convenience functions

Each wraps a serialize/pack pair. A refusal from either half propagates as
a refusal of the whole call — see each language section for what that
looks like concretely.

#### `Plink_Pack_Array`
Serializes an array to an integer array using `Plink_Pack` and
`Plink_Serialize_Array`.

#### `Plink_Pack_Table`
Serializes a map to an integer array using `Plink_Pack` and
`Plink_Serialize_Table`.

#### `Plink_Unpack_Data`
Deserializes integer-encoded data back to its original form using
`Plink_Unpack` and `Plink_Deserialize`.

Takes a nilable/optional payload, so it chains straight onto
`Plink_Pack_Array`/`Plink_Pack_Table` without a check in between: an absent
payload in is an absent result out, which is not the same thing as a
refusal (see each language section).

---

## IPC

### Version

#### `Plink_Version`
Returns version information with fields: `major`, `minor`, `rev`.

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
read as a signed 32-bit integer. A peer must read it as `uint32_t`, or
compare with masking.

**Framing:** a one-byte signature false-accepts a random word with
probability 1/256. Decoding also checks the header's packed length against
the payload actually carried, which rejects most of those. The library is
I/O agnostic, so real framing remains the caller's job.

### Command Encoding

#### `Plink_Encode_Command`
Encodes a command and its arguments into a packet. Internally uses
`Plink_Pack` for argument serialization. Refused when:

- the command number is outside `0`..`65535`,
- a key, value, or element holds a separator byte and was refused by the
  serializer,
- or the payload is too large for the header to describe.

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
argument deserialization. Refused when the signature does not match, or
when the header's packed length disagrees with the payload actually
carried.

### Command Registration

#### `Plink_Register_Command`
Register a function as the handler for a verb. Takes the handler's
contract along with the function itself: `Arg_Count`, the exact number of
entries `Arguments` must hold, and `Named`, whether it expects a map-shaped
payload (from `Plink_Serialize_Table`) or an array-shaped one (from
`Plink_Serialize_Array`). `Plink_Run_Command` checks both before calling
the handler.

#### `Plink_Run_Command`
Runs a decoded command against its registered handler. Returns `false`,
without calling the handler, when no handler is registered for that command
number, or when `Arguments` doesn't match the handler's declared `Arg_Count`
or `Named` shape (checked with the same naive "does index 1 exist"
heuristic `Plink_Encode_Command` uses on the way out). None of these cases
raise — an unknown verb, and a mismatched payload, are both routine outcomes
a peer can trigger just by disagreeing about the interface, not malformed
data — so this is the one place both implementations agree on reporting
failure through a return value rather than their refusal convention.

On a match, returns whatever the handler itself returns, unaltered — not a
bare `true`. Since `false` doubles as the failure sentinel, a handler that
legitimately returns `false` is indistinguishable from a validation failure
to the caller, in both implementations.

---

## Data Types

Three records, with the same field names and roles in both
implementations — see each language section for their concrete
representation (Teal record vs. Python `@dataclass`):

- **`Plink_Command`**: `Command` (number), `Arguments` (map)
- **`Plink_Encoded_Command`**: `Command` (number), `Encoded_Arguments`
  (array of integers)
- **`Plink_Version_Info`**: `major` (number), `minor` (number), `rev`
  (number)

---

## Lua

Source: [`Libraries/Platform_Link/Plink.tl`](../Libraries/Platform_Link/Plink.tl) ·
Tests: [`Test_Plink.tl`](../Libraries/Platform_Link/Test_Plink.tl)

Built under a size-minimizing pipeline: `just build` runs `luamin` over
`out/`, and minified size is a primary design constraint for this
implementation. When two mechanisms both solve a problem, the library takes
the shorter one.

**Refusal convention:** every function documented above as "refused"
returns `nil` instead of its normal result. There's no exception type —
check the return value.

**Pruning:** the source is regioned (`-- #region SerDes` / `-- #region
IPC`), and the SerDes region is self-contained (it owns `Escape`,
`Unescape`, and `Has_Separator`). If you're not using this library for IPC,
you can safely delete the whole `IPC` region from the source before
minifying for a smaller end artifact.

**Known TODO:** `Plink_Pack`'s inner loop could unroll `r` when `Int_Size`
is 4 or 8, if code size allows — noted in the source but not yet done.

**Data types:** the three records in [Data Types](#data-types) are Teal
records (`Plink_Command`, `Plink_Encoded_Command`, `Plink_Version_Info`),
each field typed as declared in the source.

**Testing:**

```sh
cyan build                            # type-checks and builds out/
cd Libraries/Platform_Link && tl run Test_Plink.tl
```

---

## Python

Source: [`Libraries/Platform_Link_Py/`](../Libraries/Platform_Link_Py/)
(`plink_serdes.py`, `plink_ipc.py`) ·
Tests: [`test_plink.py`](../Libraries/Platform_Link_Py/test_plink.py)

Unlike the Lua library, this port is not built under a size-minimizing
pipeline — it exists as a debug-tooling foundation. That shows up in one
deliberate divergence from the Lua source: **every refusal path that
returns `nil` in Lua raises a descriptive exception here instead.**

**Refusal convention:** every function documented above as "refused" raises
an exception deriving from `PlinkError` instead of returning `None`:

| Protocol-level refusal | Python exception |
| --- | --- |
| A key/value/element holds a separator byte | `PlinkSeparatorError`, naming the key/index and the offending value |
| `Plink_Pack`'s payload exceeds `Max_Len` | `PlinkSizeError`, with the computed length and the ceiling |
| `Plink_Pack` given non-Escape'd (non-ASCII) input — silently mangled in Lua | `PlinkEncodingError`, naming the character and position (Python-only check) |
| `Plink_Encode_Command`'s command number outside `0..65535` | `PlinkCommandRangeError`, with the value given |
| `Plink_Encode_Command`'s packed payload exceeds 255 integers | `PlinkSizeError`, with the actual count |
| `Plink_Decode_Command`'s signature mismatch | `PlinkDecodeError`, naming the header word and expected signature |
| `Plink_Decode_Command`'s packed-length mismatch | `PlinkDecodeError`, naming the claimed vs. actual length |

Two paths are **not** converted to exceptions, because they were never
refusals to begin with: `Plink_Unpack_Data(None)` still returns `None`
(an absent payload in is an absent result out, not a refusal), and
`Plink_Run_Command` still reports failure through its return value — `False`
on no handler or a mismatched payload, otherwise whatever the handler itself
returns (see [Command Registration](#command-registration) — this one's
shared across both implementations).

This trade — exceptions with actionable messages instead of Lua's
size-minimizing `nil`-propagation — is deliberate: this port exists to be a
debugging aid, not an embedded, minified artifact, so it's worth the extra
lines to say *why* something didn't decode instead of just saying it
didn't.

**Pruning:** if you only need the SerDes capability, import `plink_serdes`
directly and skip `plink_ipc` — the Python equivalent of pruning the Lua
source's IPC region. `plink_ipc` imports `plink_serdes`; nothing imports
back the other way.

**Cross-language interop specifics:**

- `Plink_Pack`/`Plink_Unpack` bit-match Lua's signed 64-bit integer
  representation (see [String Packing](#string-packing) above). Python ints
  have no fixed width on their own, so `Plink_Pack` masks each packed
  integer to 64 bits and reinterprets it as signed — two's-complemented
  above `0x7FFFFFFFFFFFFFFF` — exactly as Lua's fixed-width integer type
  would. `Plink_Unpack` reverses this by masking an incoming integer back
  to its unsigned 64-bit pattern before extracting bytes, so it decodes a
  negative Python int the same way regardless of whether that int came
  from this port's own `Plink_Pack` or from a real Lua peer.
- `Plink_Is_Valid_Command`, `Plink_Get_Packed_Len`, and
  `Plink_Decode_Command` all mask their `Command` input to its unsigned
  32-bit pattern before testing it, tolerating a header word handed in as
  a signed 32-bit int (e.g. from a C peer — see the packet header's
  portability note above).

**`Recover_Type` caveat:** this is an approximation of Lua's `tonumber` —
common decimal int/float literals round-trip, but exotic formats
`tonumber` accepts (hex literals, `inf`/`nan`, embedded underscores) may
recover differently here than on the Lua side.

**Data types:** the three records in [Data Types](#data-types) are Python
`@dataclass`es (`Plink_Command`, `Plink_Encoded_Command`,
`Plink_Version_Info`), with `Arguments`/`Encoded_Arguments` typed
`Dict[Any, Any]`/`List[int]`.

**Testing:**

```sh
pytest Libraries/Platform_Link_Py
# or, without installing pytest system-wide:
uv run --with pytest -- pytest Libraries/Platform_Link_Py
```
