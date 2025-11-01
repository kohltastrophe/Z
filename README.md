<div align="center">
	High-performance, schematized buffer serialization for Roblox Luau, inspired by <a href="https://github.com/MadStudioRoblox/Sera">Sera</a> and <a href="https://github.com/Data-Oriented-House/Squash">Squash</a>.
</div>

## Features

- **Compact:** Provides space-efficient types like variable-length integers (`Z.int`, `Z.uint`), bit-packed booleans (`Z.bool(n)`), and lossy formats (`Z.Angle8`, `Z.CFrame15`).
- **Flexible:** Supports dictionaries, arrays (`Z { Z.f64 }`), maps (`Z { [Z.uint] = Z.u16 }`), nested schemas, optionals (`Z.some`), and safe deserialization.
- **High-Performance:** Designed for speed with features like a pre-allocated scratch buffer to minimize memory allocations.
- **Schema-Based:** Enforces a strict data structure for reliable serialization.

## Installation

1.  Download [`init.luau`](src/init.luau) from the `src/` directory.
2.  Place the file into your project (e.g., `ReplicatedStorage/Modules/Z`).
3.  Require the module in your script:

```luau
local Z = require(game.ReplicatedStorage.Modules.Z)
```

## Basic Usage

```luau
local Z = require(game.ReplicatedStorage.Modules.Z)

-- 1. Define a schema (a "blueprint" for your data)
local PlayerDataSchema = Z {
	Name = Z.str8, -- A string with a max length of 2^8-1
	Health = Z.u8, -- An unsigned 8-bit integer
	IsAdmin = Z.some(Z.bool), -- An optional boolean
	Inventory = Z { Z.str8 }, -- A list of strings
	Position = Z.Vector3,
}

-- 2. Create data that matches the schema
local data = {
	Name = "Kohl",
	Health = 100,
	IsAdmin = true,
	Inventory = { "Sword", "Shield", "Potion" },
	Position = Vector3.new(10, 5, -20),
}

-- 3. Serialize the data (table -> buffer)
local serializedBuffer, err = Z.ser(PlayerDataSchema, data)
assert(serializedBuffer, err)
print(`Serialized data to {buffer.len(serializedBuffer)} bytes`)

-- 4. Deserialize the data (buffer -> table)
local deserializedData, _bytesRead = Z.des(PlayerDataSchema, serializedBuffer)
print("Deserialized Data:", deserializedData)
```

## API Reference

### `Z.schema(definition)` or `Z(definition)`

Creates a new schema from a definition table.

- **Dictionary Schema:** `Z { KeyA = Z.u8, KeyB = Z.f32 }`
  - Keys are sorted alphabetically for consistent serialization.
- **List Schema:** `Z { Z.f64 }`
  - Defines a schema for a list of a single `ZType`.
- **Map Schema:** `Z { [Z.uint] = Z.u16 }`
  - Defines a schema for a map of a `ZType` key to a `ZType` value.
- **Limit List/Map Schemas:** `Z(8/16/32) { [Z.uint] = Z.u16 }`
  - Sets the maximum number of items to `2^8-1`, `2^16-1`, or `2^32-1`. Defaults to `u32`.

### `Z.ser(schema, object, buffer?, offset?)`

Serializes a Luau `object` according to the `schema`.

- If `buffer` is **omitted**, it returns a **new buffer** containing the serialized data.
- If `buffer` is **provided**, it writes into that buffer and returns the **new offset** (the position after the written data).
- **Returns:** `(buffer | number, nil)` on success, or `(nil, string)` on error.

### `Z.des(schema, buffer, offset?, safe?)`

Deserializes binary data from a `buffer` into a new table.

- `offset` defaults to `0`.
- `safe` defaults to `false`. If `true`, it suppresses errors from incomplete data (e.g., if the buffer is truncated). This is useful for reading data from streams.
- **Returns:** `(deserializedObject, nextOffset)`.

### `Z.some(ZType)`

Wraps any `ZType` (including other schemas) to make it optional. This adds a 1-byte overhead.

- If the value is `nil`, it writes a single `0` byte.
- If the value is present, it writes a `1` byte followed by the value's serialized data.

## Supported Data Types

| ZType                       | Description                                | Size (bytes)                |
| :-------------------------- | :----------------------------------------- | :-------------------------- |
| **Primitives**              |                                            |                             |
| `Z.bool`                    | Boolean                                    | 1                           |
| `Z.bool(n)`                 | Bit-packed list of `n` booleans            | `ceil(n / 8)`               |
| `Z.u8` / `Z.i8`             | (Un)signed 8-bit integer                   | 1                           |
| `Z.u16` / `Z.i16`           | (Un)signed 16-bit integer                  | 2                           |
| `Z.u32` / `Z.i32`           | (Un)signed 32-bit integer                  | 4                           |
| `Z.f32` / `Z.f64`           | 32/64-bit float                            | 4 / 8                       |
| **Variable-Length**         |                                            |                             |
| `Z.uint`                    | Unsigned LEB128 integer                    | 1-8                         |
| `Z.int`                     | Signed LEB128 integer                      | 1-8                         |
| **Strings / Buffers**       |                                            |                             |
| `Z.byte`                    | Single byte (as 1-char string)             | 1                           |
| `Z.str8/16/32`              | String (max length 2^8/16/32 - 1)          | 1/2/4 + N                   |
| `Z.buffer8/16/32`           | Buffer (max length 2^8/16/32 - 1)          | 1/2/4 + N                   |
| **Tables**                  |                                            |                             |
| `Z.table`                   | Naive table (inefficient)                  | ?                           |
| `Z(8/16/32){ZType}`         | List ZType (max items 2^8/16/32 - 1)       | 1/2/4 + N ZType             |
| `Z(8/16/32){[ZType]=ZType}` | Map ZType (max items 2^8/16/32 - 1)        | 1/2/4 + N (ZType1 + ZType2) |
| **Roblox Data Types**       |                                            |                             |
| `Z.Angle8`                  | Lossy rotation (maps `2*pi` to 255 values) | 1                           |
| `Z.Axes`                    | `Axes`                                     | 2                           |
| `Z.BrickColor`              | `BrickColor`                               | 2                           |
| `Z.CFrame`                  | Full `CFrame` (12x `f32`)                  | 48                          |
| `Z.CFrame28`                | Lossy `CFrame` (Pos + 4x `f32` Orient)     | 28                          |
| `Z.CFrame15`                | Lossy `CFrame` (Pos + 3x `Angle8` Orient)  | 15                          |
| `Z.Color3`                  | `Color3` (3x `u8`)                         | 3                           |
| `Z.ColorSequence`           | `ColorSequence`                            | 1 + 4N points               |
| `Z.ColorSequenceKeypoint`   | `ColorSequenceKeypoint`                    | 4                           |
| `Z.DateTime`                | `DateTime`                                 | 8                           |
| `Z.EnumItem`                | `EnumItem` (inefficient)                   | 2-5 + #EnumType             |
| `Z.EnumItem(enum)`          | `EnumItem` (optimized)                     | 1-4                         |
| `Z.Faces`                   | `Faces`                                    | 1                           |
| `Z.FloatCurveKey`           | `FloatCurveKey`                            | 12-19                       |
| `Z.Font`                    | `Font`                                     | 2-257                       |
| `Z.NumberRange`             | `NumberRange` (2x `f64`)                   | 16                          |
| `Z.NumberSequence`          | `NumberSequence`                           | 1 + 12N points              |
| `Z.NumberSequenceKeypoint`  | `NumberSequenceKeypoint`                   | 12                          |
| `Z.Path2DControlPoint`      | `Path2DControlPoint` (3x `some(UDim2)`)    | 3-51                        |
| `Z.PathWaypoint`            | `PathWaypoint`                             | 14-269                      |
| `Z.PhysicalProperties`      | `PhysicalProperties` (5x `f32`)            | 20                          |
| `Z.Ray`                     | `Ray` (2x `Vector3`)                       | 24                          |
| `Z.Rect`                    | `Rect` (2x `Vector2`)                      | 16                          |
| `Z.Region3`                 | `Region3` (2x `Vector3`)                   | 24                          |
| `Z.Region3int16`            | `Region3int16` (2x `Vector3i16`)           | 12                          |
| `Z.RotationCurveKey`        | `RotationCurveKey`                         | 55-63                       |
| `Z.TweenInfo`               | `TweenInfo`                                | 13                          |
| `Z.UDim`                    | `UDim` (2x `f32`)                          | 8                           |
| `Z.UDim2`                   | `UDim2` (4x `f32`)                         | 16                          |
| `Z.Vector2`                 | `Vector2` (2x `f32`)                       | 8                           |
| `Z.Vector2i16`              | `Vector2int16` (2x `i16`)                  | 4                           |
| `Z.Vector3`                 | `Vector3` (3x `f32`)                       | 12                          |
| `Z.Vector3i16`              | `Vector3int16` (3x `i16`)                  | 6                           |

## Configuration

- `Z.TRIM_STRINGS: boolean` (Default: `false`)
  - If `true`, strings exceeding the max length for their type (`str8`, `str16`, `str32`) will be truncated instead of causing an error.

## License

This project is available under the [MIT License](LICENSE.md).
