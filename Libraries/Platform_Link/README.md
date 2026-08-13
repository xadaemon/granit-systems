# Platform_Link

Platform Link is a concise library for data exchange using a compact encoding. It is agnostic of I/O and designed to be easy to use and flexible. The library enables RPC between peers.

Formats and specifics for the encodings are specified in the documentation of each function that encodes.

**Note:** If not being used for IPC purposes and only for the SerDes capability, you can safely prune the whole IPC region for a smaller minified end code.

## Relevant Functions

- `Plink_Serialize_Table/Array`
- `Plink_Encode_Command`
- `Plink_Encode_Params`

---

## SerDes

### Serialization

#### Plink_Serialize_Table
Encodes a map of parameters to a string in the form of:
```
!key:value;...keyn:valuen;
```
for map-shaped tables (key ordering not guaranteed) or
```
$value;...valuen;
```
for array-shaped tables.

**Note:** This format cannot support sub-tables. This is a deliberate choice to keep the format simple and avoid recursion.

#### Plink_Serialize_Array
See `Plink_Serialize_Table` for format details. Does the same but with arrays.

### Type Recovery

#### Recover_Type
Recover a type from a string.

### Deserialization

#### Plink_Deserialize
Decodes parameters encoded by `Plink_Encode_Params`. See that function for details on the format.

### String Encoding

#### Plink_Pack
Packs a string consisting of ASCII characters only into a series of integers. Each byte is encoded in the form:

For each byte `b` at position `i`:
- Let `w` be the width of an integer
- Let `j` be the index within an integer (`j % w`)
- Let `r` be the integer being composed
- `r := r | (128 | b) << (j * 8)`

This allows indication of which bytes of the integer are occupied by string characters.

**Note:** TODO: Improve the code to unroll `r` when `r` is 4 or 8 (if code size allows).

#### Plink_Unpack
Decodes a string encoded by `Plink_Pack`. See the documentation on that function for details about the encoding.

### Convenience Functions

#### Plink_Pack_Array
Serializes an array to an integer array using `Plink_Pack` and `Plink_Serialize_Array`.

#### Plink_Pack_Table
Serializes a table to an integer array using `Plink_Pack` and `Plink_Serialize_Table`.

#### Plink_Unpack_Data
Deserializes integer-encoded data back to its original form using `Plink_Unpack` and `Plink_Deserialize`.

---

## IPC

### Version

#### Plink_Version
Returns version information as `Plink_Version_Info` with fields: `major`, `minor`, `rev`.

### Command Encoding

#### Plink_Encode_Command
Encodes a command and its arguments into a packet. Internally uses `Plink_Pack` for argument serialization.

#### Plink_Is_Valid_Command
Checks if a command is valid.

#### Plink_Get_Arg_Len
Get the number of arguments for the given command.

**Parameters:**
- `Command`: any

**Returns:** integer

#### Plink_Decode_Command
Decodes a command from a packet. Internally uses `Plink_Unpack` for argument deserialization.

### Command Registration

#### Plink_Register_Command
Register a function as the handler for a verb.

#### Plink_Run_Command
Runs a decoded Command.

---

## Data Types

### Records

- `Plink_Command`: Contains `Command` (number) and `Arguments` ({any})
- `Plink_Encoded_Command`: Contains `Command` (number) and `Encoded_Arguments` ({number})
- `Plink_Version_Info`: Contains `major` (number), `minor` (number), `rev` (number)
