# Platform_Link

Platform Link is a concise library for data exchange using a compact encoding. It is agnostic of I/O and designed to be easy to use and flexible. The library enables RPC between peers.

Formats and specifics for the encodings are specified in the documentation of each function that encodes.

**Note:** If not being used for IPC purposes and only for the SerDes capability, you can safely prune the whole IPC region for a smaller minified end code. The SerDes region is self contained: it owns `Escape`, `Unescape` and `Has_Separator`.

## Relevant Functions

- `Plink_Serialize_Table/Array`
- `Plink_Deserialize`
- `Plink_Encode_Command`

---

## SerDes

### Wire format

Records are delimited by ASCII control codes, so no printable byte is ever special — `:`, `;`, `/` and friends are ordinary data. The shape marker at the very start of the frame is a control byte too, so this holds for the entire frame, not just the records within it.

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

The leading `DC1`/`DC2` sigil is stripped once by the parser, so a key or value may itself begin with a `DC1` or `DC2` byte.

### Escaping

Keys and values are percent-escaped on the way out and unescaped on the way in:

| Input | Becomes |
| --- | --- |
| `%` | `%25` |
| any byte `>= 0x80` | `%XX` |

`%` is escaped first, so `%XX` sequences are never ambiguous. The high-byte pass is what makes non-ASCII survive: `Plink_Pack` uses bit 7 of every byte as an occupancy flag and would otherwise mangle it. UTF-8 round-trips, at 3x size for the non-ASCII bytes.

**The separators themselves are not escaped.** A key or value containing `0x1F` or `0x1E` cannot be represented, and the serializers return `nil` rather than emit a frame that would silently truncate on the far side.

### Serialization

#### Plink_Serialize_Table
Encodes a map of parameters to the map form above (key ordering not guaranteed). Returns `string | nil` — `nil` when any key or value holds a separator byte.

**Note:** This format cannot support sub-tables. This is a deliberate choice to keep the format simple and avoid recursion.

#### Plink_Serialize_Array
See `Plink_Serialize_Table` for format details. Does the same but with arrays, emitting the array form. Also returns `string | nil`.

### Type Recovery

#### Recover_Type
Recover a type from a string. `"true"`/`"false"` become booleans, anything `tonumber` accepts becomes a number, everything else stays a string. Note this is lossy: the string `"10"` comes back as the number `10`.

### Deserialization

#### Plink_Deserialize
Decodes a string produced by `Plink_Serialize_Table` or `Plink_Serialize_Array`. See those functions for details on the format. The leading sigil selects which shape is recovered; anything else yields an empty table.

Returns `{any: any}` — a map type rather than an array, because either shape can come back and this keeps a deserialized map indexable by key. The cost is that `#` does not work on the result; count an array-shaped result by walking it.

### String Encoding

#### Plink_Pack
Packs a string consisting of ASCII characters only into a series of integers. Each byte is encoded in the form:

For each byte `b` at position `i`:
- Let `w` be the width of an integer
- Let `j` be the index within an integer (`j % w`)
- Let `r` be the integer being composed
- `r := r | (128 | b) << (j * 8)`

This allows indication of which bytes of the integer are occupied by string characters. Because bit 7 carries that flag, only bytes `0x00`–`0x7F` survive — feed it `Escape`'d data.

`Max_Len` defaults to **255 integers = 2040 bytes**, the largest payload a Plink header can describe. Returns `{integer} | nil`, `nil` when the input exceeds the cap.

**Note:** TODO: Improve the code to unroll `r` when `r` is 4 or 8 (if code size allows).

#### Plink_Unpack
Decodes a string encoded by `Plink_Pack`. See the documentation on that function for details about the encoding. Returns `string`.

### Convenience Functions

Each wraps a serialize/pack pair and propagates a refusal as `nil` rather than raising downstream.

#### Plink_Pack_Array
Serializes an array to an integer array using `Plink_Pack` and `Plink_Serialize_Array`. Returns `{integer} | nil`.

#### Plink_Pack_Table
Serializes a table to an integer array using `Plink_Pack` and `Plink_Serialize_Table`. Returns `{integer} | nil`.

#### Plink_Unpack_Data
Deserializes integer-encoded data back to its original form using `Plink_Unpack` and `Plink_Deserialize`. Returns `{any: any} | nil`.

Takes a **nilable** payload, so it chains straight onto `Plink_Pack_Array`/`Plink_Pack_Table` without a check in between:

```lua
local Data = Plink_Unpack_Data(Plink_Pack_Table(Params))
if Data is nil then
    -- the payload was refused or too large
end
```

---

## IPC

### Version

#### Plink_Version
Returns version information as `Plink_Version_Info` with fields: `major`, `minor`, `rev`.

### Packet header

A command is one integer with three non-overlapping fields, byte-aligned as `[0xAA][command hi][command lo][packed length]`:

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
| Signature | 31..24 | `0xAA` (`10101010`) | `2852126720`, mask `4278190080` |
| Command number | 23..8 | `0`..`65535` | `<< 8`, `& 65535` |
| Packed length | 7..0 | `0`..`255` (2040 bytes) | `& 255` |

The packed length counts **integers in `Encoded_Arguments`**, not decoded arguments.

**Portability:** `0xAA000000` sets bit 31, so this word is negative when read as a signed 32-bit integer. A C or embedded peer must read it as `uint32_t`, or compare with masking.

**Framing:** a one-byte signature false-accepts a random word with probability 1/256. `Plink_Decode_Command` also checks the header's packed length against the payload actually carried, which rejects most of those. The library is I/O agnostic, so real framing remains the caller's job.

### Command Encoding

#### Plink_Encode_Command
Encodes a command and its arguments into a packet. Internally uses `Plink_Pack` for argument serialization. Returns `Plink_Encoded_Command | nil`, with `nil` when:

- the command number is outside `0`..`65535`,
- a key or value holds a separator byte and was refused by the serializer,
- or the payload is too large for the header to describe.

#### Plink_Is_Valid_Command
Checks if a command is valid by matching the signature field against `0xFF << 24`.

#### Plink_Get_Packed_Len
Get the length of the packed payload of a command, that is how many integers `Encoded_Arguments` holds. This is *not* the number of arguments the payload decodes to — the argument count is only known after unpacking.

**Returns:** the packed length, or `-1` when the command is not a valid Plink packet.

#### Plink_Decode_Command
Decodes a command from a packet. Internally uses `Plink_Unpack` for argument deserialization. Returns `Plink_Command | nil`, with `nil` when the signature does not match or when the header's packed length disagrees with the payload carried.

### Command Registration

#### Plink_Register_Command
Register a function as the handler for a verb.

#### Plink_Run_Command
Runs a decoded Command. Returns `boolean`: `false` when no handler is registered for that command number, so an unknown verb from a peer is a rejection rather than a raise.

---

## Data Types

### Records

- `Plink_Command`: Contains `Command` (number) and `Arguments` (`{any: any}`)
- `Plink_Encoded_Command`: Contains `Command` (number) and `Encoded_Arguments` (`{number}`)
- `Plink_Version_Info`: Contains `major` (number), `minor` (number), `rev` (number)
