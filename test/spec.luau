local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SIZE_8 = 2 ^ 8 - 1
local SIZE_16 = 2 ^ 16 - 1
local SIZE_32 = 2 ^ 32 - 1

local Z = require(ReplicatedStorage:WaitForChild("Z")) :: any

local function DEEP_EQUALS(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not DEEP_EQUALS(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

-- circular comparison: 0 and 2*pi are the same angle
local function ANGLE_EQUALS(tolerance)
	return function(a, b)
		local diff = math.atan2(math.sin(a - b), math.cos(a - b))
		return math.abs(diff) <= tolerance
	end
end

local function check(zType, value, equals)
	equals = equals or DEEP_EQUALS
	local schema = Z.schema({ Value = zType })
	local data = { Value = value }

	local serBuffer, err = Z.ser(schema, data)
	if not serBuffer then
		error(`Failed to serialize {zType.name}: {err}`, 2)
	end

	local desData, _bytesRead = Z.des(schema, serBuffer)
	if not desData then
		error(`Failed to deserialize {zType.name}`, 2)
	end

	if not equals(value, desData.Value) then
		error(`Value mismatch for {zType.name}: expected {value}, got {desData.Value}`, 2)
	end
end

local tests = {
	["Configuration"] = function()
		Z.TRIM_STRINGS = true
		local schema = Z.schema { Value = Z.str8 }
		local data = { Value = string.rep("a", 257) }
		local ser, err = Z.ser(schema, data)
		assert(ser, `Failed to serialize with TRIM_STRINGS: {err}`)
		local des, _ = Z.des(schema, ser)
		assert(des, "Failed to deserialize with TRIM_STRINGS")
		assert(string.len(des.Value) == SIZE_8, `TRIM_STRINGS failed: expected length 255, got {string.len(des.Value)}`)
		Z.TRIM_STRINGS = false
	end,

	["CFrame15 Rotation"] = function()
		local schema = Z.schema { Value = Z.CFrame15 }
		local cases = {
			CFrame.fromOrientation(math.rad(90), math.rad(45), 0),
			CFrame.fromOrientation(math.rad(45), math.rad(45), math.rad(45)),
			CFrame.new(1, 2, 3) * CFrame.Angles(0.1, 0.2, 0.3),
			CFrame.fromOrientation(math.rad(170), math.rad(-120), math.rad(80)) + Vector3.new(10, -5, 3),
			-- angles just under 360 degrees round to byte 256 and must wrap, not
			-- carry into the adjacent packed angle byte
			CFrame.new(5, 5, 5) * CFrame.fromOrientation(-1e-9, math.rad(359.9), math.rad(359.8)),
		}

		local rng = Random.new(7)
		for _ = 1, 20 do
			table.insert(
				cases,
				CFrame.new(rng:NextNumber(-100, 100), rng:NextNumber(-100, 100), rng:NextNumber(-100, 100))
					* CFrame.fromOrientation(
						rng:NextNumber(-math.pi, math.pi),
						rng:NextNumber(-math.pi, math.pi),
						rng:NextNumber(-math.pi, math.pi)
					)
			)
		end

		for i, cf in cases do
			local ser, err = Z.ser(schema, { Value = cf })
			assert(ser, `Failed to serialize CFrame15 case {i}: {err}`)
			local des = Z.des(schema, ser)
			assert(
				des.Value:FuzzyEq(cf, 0.1),
				`CFrame15 rotation mismatch for case {i}: expected {cf}, got {des.Value}`
			)
		end
	end,

	["Cyclic Tables"] = function()
		local cyclic = {}
		cyclic.self = cyclic
		local result, err = Z.ser(Z.table, cyclic)
		assert(result == nil, "cyclic table should fail to serialize")
		assert(string.find(err, "cyclic"), `cyclic table error should mention the cycle, got: {err}`)

		-- shared (non-cyclic) references from sibling branches are allowed and
		-- serialize as independent copies
		local shared = { a = 1 }
		check(Z.table, { x = shared, y = shared })
	end,

	["Direct ZType"] = function()
		local ser, err = Z.ser(Z.u8, SIZE_8)
		assert(ser, `Failed to serialize u8 directly: {err}`)

		local desData, _bytesRead = Z.des(Z.u8, ser)
		assert(desData == SIZE_8, `Failed to deserialize u8 directly`)

		-- safe must suppress errors for primitive ZType roots too, not only schemas
		local safeDes = Z.des(Z.str32, buffer.create(2), 0, true)
		assert(safeDes == nil, `safe des of a primitive on incomplete data should return nil, got {safeDes}`)
	end,

	["Error Reporting"] = function()
		local _, missingErr = Z.ser(Z.schema { Name = Z.str8 }, {})
		assert(
			missingErr and string.find(missingErr, 'Missing field "Name"'),
			`expected Missing field error, got: {missingErr}`
		)

		-- a legitimately nil optional field must not mask the real error
		local optSchema = Z.schema { a = Z.some(Z.u8), b = Z.str8 }
		local _, boundsErr = Z.ser(optSchema, { a = nil, b = string.rep("x", 300) })
		assert(boundsErr, "oversized field should fail to serialize")
		assert(not string.find(boundsErr, 'Missing field "a"'), `nil optional misreported as missing: {boundsErr}`)
		assert(string.find(boundsErr, "bounds"), `error should surface the bounds failure, got: {boundsErr}`)

		local ok, schemaErr = pcall(Z.schema, { Value = 5 })
		assert(not ok, "schema with a non-ZType value should error")
		assert(
			string.find(tostring(schemaErr), '"number"'),
			`schema error should name the value's type, got: {schemaErr}`
		)
	end,

	["Exact Buffers"] = function()
		-- types must write exactly the bytes they claim: serializing into an
		-- exactly-sized caller buffer must not go out of bounds
		local color = Color3.fromRGB(12, 200, 255)
		local colorSchema = Z.schema { Value = Z.Color3 }
		local colorBuffer = buffer.create(3)
		local colorOffset, colorErr = Z.ser(colorSchema, { Value = color }, colorBuffer, 0)
		assert(colorOffset == 3, `Color3 should fit a 3-byte buffer: offset {colorOffset}, error {colorErr}`)
		assert(Z.des(colorSchema, colorBuffer).Value == color, "Color3 exact-buffer roundtrip failed")

		local cf = CFrame.fromOrientation(math.rad(90), math.rad(45), 0)
		local cfSchema = Z.schema { Value = Z.CFrame15 }
		local cfBuffer = buffer.create(15)
		local cfOffset, cfErr = Z.ser(cfSchema, { Value = cf }, cfBuffer, 0)
		assert(cfOffset == 15, `CFrame15 should fit a 15-byte buffer: offset {cfOffset}, error {cfErr}`)
	end,

	["Fonts"] = function()
		local family = "rbxasset://fonts/families/SourceSansPro.json"
		local weights = {
			Enum.FontWeight.Light,
			Enum.FontWeight.Regular,
			Enum.FontWeight.SemiBold,
			Enum.FontWeight.Bold,
			Enum.FontWeight.ExtraBold,
			Enum.FontWeight.Heavy,
		}
		for _, weight in weights do
			for _, style in { Enum.FontStyle.Normal, Enum.FontStyle.Italic } do
				-- every weight must roundtrip exactly: heavier-than-Bold weights
				-- must not collapse to Bold
				check(Z.Font, Font.new(family, weight, style))
			end
		end
	end,

	["Hostile Input"] = function()
		-- a forged length prefix far larger than the buffer must not cause a
		-- huge allocation: safe mode returns nil, unsafe mode errors
		local hostile = buffer.create(4)
		buffer.writeu32(hostile, 0, SIZE_32)

		local listSchema = Z.schema { Z.u8 }
		local safeList = Z.des(listSchema, hostile, 0, true)
		assert(safeList == nil, "safe des of hostile list length should return nil")
		assert(not pcall(Z.des, listSchema, hostile, 0, false), "unsafe des of hostile list length should error")

		local mapSchema = Z.schema { [Z.u8] = Z.u8 }
		local safeMap = Z.des(mapSchema, hostile, 0, true)
		assert(safeMap == nil, "safe des of hostile map length should return nil")
		assert(not pcall(Z.des, mapSchema, hostile, 0, false), "unsafe des of hostile map length should error")

		assert(not pcall(Z.table.read, hostile, 0), "Z.table.read of a hostile length should error")
		assert(not pcall(Z.buffer32.read, hostile, 0), "Z.buffer32.read of a hostile length should error")

		-- a field that fails to decode in safe mode aborts the whole read and
		-- returns nil, rather than a partially-decoded struct
		local structSchema = Z.schema { a = Z.f64, b = Z.u8 }
		local truncated = buffer.create(1)
		buffer.writeu8(truncated, 0, 77)
		local safeStruct = Z.des(structSchema, truncated, 0, true)
		assert(safeStruct == nil, `safe des of a truncated struct should return nil, got {safeStruct}`)
	end,

	["Limits"] = function()
		check(Z.schema8 { Z.u8 }, table.create(SIZE_8, SIZE_8))
		check(Z.schema16 { Z.u16 }, table.create(SIZE_16, SIZE_16))
		check(Z.schema32 { Z.u32 }, table.create(SIZE_16 + 1, SIZE_32))

		local map8 = {}
		for i = 1, SIZE_8 do
			map8[tostring(i)] = i
		end
		check(Z.schema8 { [Z.str8] = Z.u8 }, map8)

		local map16 = {}
		for i = 1, SIZE_16 do
			map16[tostring(i)] = i
		end
		check(Z.schema16 { [Z.str8] = Z.u16 }, map16)

		local map32 = {}
		for i = 1, SIZE_16 + 1 do
			map32[tostring(i)] = i
		end
		check(Z.schema32 { [Z.str8] = Z.u32 }, map32)
	end,

	["Migrate"] = function()
		local oldSchema = Z.schema { name = Z.str8, level = Z.u8 }
		local newSchema = Z.schema { name = Z.str8, level = Z.u16, title = Z.some(Z.str8) }

		local oldBuffer = Z.ser(oldSchema, { name = "kohl", level = 100 })
		local migrated, err = Z.migrate(oldSchema, newSchema, oldBuffer, function(data)
			data.level *= 2
			return data
		end)
		assert(migrated, `migrate failed: {err}`)
		local migratedData = Z.des(newSchema, migrated)
		assert(
			migratedData.name == "kohl" and migratedData.level == 200 and migratedData.title == nil,
			"migrated data mismatch"
		)

		-- serialization failures inside migrate must propagate as an error value
		local failResult, failErr = Z.migrate(oldSchema, oldSchema, oldBuffer, function(data)
			data.name = string.rep("a", 300)
			return data
		end)
		assert(failResult == nil and failErr ~= nil, `migrate should propagate ser errors, got {failResult}, {failErr}`)

		-- truncated input is rejected instead of migrating partial data
		local truncated = buffer.create(2)
		buffer.copy(truncated, 0, oldBuffer, 0, 2)
		local truncResult, truncErr = Z.migrate(oldSchema, newSchema, truncated)
		assert(truncResult == nil, `truncated migrate should fail, got {truncResult}`)
		assert(string.find(truncErr, "Incomplete"), `expected Incomplete data error, got: {truncErr}`)

		-- an empty buffer must not crash the change callback with nil data
		local listSchema = Z.schema { Z.u8 }
		local ok = pcall(Z.migrate, listSchema, listSchema, buffer.create(0), function(data)
			assert(data ~= nil, "migrate passed nil to change()")
			return data
		end)
		assert(ok, "migrate of an empty buffer should not crash")
	end,

	["Mixed Keys"] = function()
		-- definitions mixing number and string keys are valid and must sort
		-- deterministically instead of erroring
		local schema = Z.schema { [2] = Z.u8, Name = Z.str8 }
		local data = { [2] = 9, Name = "n" }
		local ser, err = Z.ser(schema, data)
		assert(ser, `Failed to serialize mixed-key schema: {err}`)
		assert(DEEP_EQUALS(data, Z.des(schema, ser)), "mixed-key roundtrip failed")
	end,

	["Nested Schemas"] = function()
		local schema = Z.schema {
			nested = Z.schema { value = Z.u8 },
			list = Z.schema8 { Z.u16 },
			map = Z.schema8 { [Z.str8] = Z.u8 },
		}
		local data = {
			nested = { value = 255 },
			list = { 1, 500, 3 },
			map = { a = 1, b = 2 },
		}
		local ser, err = Z.ser(schema, data)
		assert(ser, `Failed to serialize nested schemas: {err}`)

		local desData, _bytesRead = Z.des(schema, ser)
		assert(DEEP_EQUALS(data, desData), `Failed to deserialize nested schemas`)
	end,

	["Optionals"] = function()
		check(Z.some(Z.u8), nil)
		check(Z.some(Z.u8), 123)
		check(Z.some(Z.Vector3), nil)
		check(Z.some(Z.Vector3), Vector3.new(1, 2, 3))

		-- wrapper names resolve lazily so they work for wrappers created at
		-- module load, before names are assigned
		assert(Z.some(Z.u8).name == "some(u8)", `unexpected some name: {Z.some(Z.u8).name}`)
		assert(Z.some(Z.Vector3).name == "some(Vector3)", `unexpected some name: {Z.some(Z.Vector3).name}`)
	end,

	["Out Of Bounds"] = function()
		assert(not Z.ser(Z.str8, string.rep("a", 256)), "str8 should fail with length 256")
		assert(not Z.ser(Z.buffer8, buffer.create(256)), "buffer8 should fail with length 256")
		assert(not Z.ser(Z.schema8 { Z.u8 }, table.create(256, 0)), "list with 8bit length should fail with 256 items")
		assert(
			not Z.ser(Z.schema8 { [Z.u8] = Z.u8 }, table.create(256, 0)),
			"map with 8bit length should fail with 256 items"
		)

		-- maxSize must reject oversized output instead of silently truncating
		local schema = Z.schema { Value = Z.str16 }
		local result, err = Z.ser(schema, { Value = string.rep("x", 200) }, nil, nil, 64)
		assert(result == nil, `maxSize should reject oversized output, got {result}`)
		assert(string.find(err, "maxSize"), `expected maxSize error, got: {err}`)
		assert(Z.ser(schema, { Value = "ok" }, nil, nil, 64), "maxSize should allow output that fits")
	end,

	["Primitives"] = function()
		check(Z.bool, true)
		check(Z.bool, false)
		check(Z.bools, { true, false, true }, function(a, b)
			-- bools always decodes 8 flags; unwritten positions read back false
			for i = 1, 8 do
				if (a[i] or false) ~= (b[i] or false) then
					return false
				end
			end
			return true
		end)
		check(Z.u8, 2 ^ 8 - 1)
		check(Z.u16, 2 ^ 16 - 1)
		check(Z.u32, 2 ^ 32 - 1)
		check(Z.i8, -2 ^ 7)
		check(Z.i16, -2 ^ 15)
		check(Z.i32, -2 ^ 31)
		check(Z.f32, math.pi, function(a, b)
			return math.abs(a - b) < 1e-6
		end)
		check(Z.f64, math.pi)
	end,

	["Roblox Types"] = function()
		check(Z.Angle8, math.pi, ANGLE_EQUALS(2 * math.pi / 254))
		-- angles just under 2*pi quantize to 256 and must wrap to 0 (the same
		-- angle circularly) instead of overflowing the byte
		check(Z.Angle8, math.rad(359.9), ANGLE_EQUALS(2 * math.pi / 254))
		check(Z.Angle8, -1e-9, ANGLE_EQUALS(2 * math.pi / 254))
		check(Z.Axes, Axes.new(Enum.NormalId.Top, Enum.Axis.Y))
		check(Z.BrickColor, BrickColor.Random())
		check(Z.CFrame, CFrame.new(1, 2, 3) * CFrame.Angles(0.1, 0.2, 0.3))
		check(Z.CFrame28, CFrame.new(1, 2, 3) * CFrame.Angles(0.1, 0.2, 0.3), function(a: CFrame, b: CFrame)
			return a:FuzzyEq(b)
		end)
		check(Z.CFrame15, CFrame.new(1, 2, 3) * CFrame.Angles(0.1, 0.2, 0.3), function(a: CFrame, b: CFrame)
			return a:FuzzyEq(b, 0.1)
		end)
		check(Z.Color3, Color3.fromRGB(0, 128, 255))
		check(
			Z.ColorSequence,
			ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.new(1, 0, 0)),
				ColorSequenceKeypoint.new(1, Color3.new(0, 0, 1)),
			})
		)
		check(Z.ColorSequenceKeypoint, ColorSequenceKeypoint.new(127 / 255, Color3.fromRGB(127, 127, 127)))
		check(Z.DateTime, DateTime.now())
		check(Z.EnumItem, Enum.Material.Wood)
		check(Z.EnumItem(Enum.Material), Enum.Material.Wood)
		check(Z.Faces, Faces.new(Enum.NormalId.Front))
		check(Z.FloatCurveKey, FloatCurveKey.new(0.5, 0.5, Enum.KeyInterpolationMode.Linear))
		check(Z.NumberRange, NumberRange.new(10, 20))
		check(
			Z.NumberSequence,
			NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		)
		check(Z.NumberSequenceKeypoint, NumberSequenceKeypoint.new(0.5, 0.5, 0.5))
		check(
			Z.Path2DControlPoint,
			Path2DControlPoint.new(UDim2.new(0, 1, 0, 2), UDim2.new(0, 3, 0, 4), UDim2.new(0, 5, 0, 6))
		)
		check(Z.PathWaypoint, PathWaypoint.new(Vector3.new(1, 2, 3), Enum.PathWaypointAction.Walk))
		check(Z.PhysicalProperties, PhysicalProperties.new(0.1, 0.2, 0.3, 0.4, 0.5))
		check(Z.Ray, Ray.new(Vector3.new(1, 2, 3), Vector3.new(4, 5, 6)))
		check(Z.Rect, Rect.new(1, 2, 3, 4))
		check(Z.Region3, Region3.new(Vector3.new(1, 2, 3), Vector3.new(4, 5, 6)))
		check(Z.Region3int16, Region3int16.new(Vector3int16.new(1, 2, 3), Vector3int16.new(4, 5, 6)))
		check(
			Z.RotationCurveKey,
			RotationCurveKey.new(0.5, CFrame.Angles(0.1, 0.2, 0.3), Enum.KeyInterpolationMode.Cubic),
			function(a: RotationCurveKey, b: RotationCurveKey)
				return a.Interpolation == b.Interpolation
					and a.Time == b.Time
					and a.Value:FuzzyEq(b.Value)
					and a.RightTangent == b.RightTangent
					and a.LeftTangent == b.LeftTangent
			end
		)
		check(Z.TweenInfo, TweenInfo.new(1, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, 2, true, 0.5))
		check(Z.UDim, UDim.new(0.1, 2))
		check(Z.UDim2, UDim2.new(0.1, 2, 0.3, 4))
		check(Z.Vector2, Vector2.new(1, 2))
		check(Z.Vector2int16, Vector2int16.new(1, 2))
		check(Z.Vector3, Vector3.new(1, 2, 3))
		check(Z.Vector3int16, Vector3int16.new(1, 2, 3))
	end,

	["Serialization"] = function()
		local schema = Z.schema { Value = Z.u16 }
		local data = { Value = 2 ^ 16 - 1 }

		local buf = buffer.create(10)
		local offset = 5
		local nextOffset, err = Z.ser(schema, data, buf, offset)
		assert(nextOffset, `ser with buffer failed: {err}`)
		assert(
			nextOffset == offset + 2,
			`ser with buffer returned wrong offset: expected {offset + 2}, got {nextOffset}`
		)

		local desData, desOffset = Z.des(schema, buf, offset)
		assert(desData, "des with offset failed")
		assert(
			desData.Value == data.Value,
			`des with offset returned wrong data: expected {data.Value}, got {desData.Value}`
		)
		assert(desOffset == nextOffset, `des with offset returned wrong offset: expected {nextOffset}, got {desOffset}`)

		local truncatedBuffer = buffer.create(1)
		buffer.copy(truncatedBuffer, 0, buf, offset, 1)
		local safeDes, safeDesOffset = Z.des(schema, truncatedBuffer, 0, true)
		assert(safeDes == nil, `safe des should return nil on incomplete data, got {safeDes}`)
		assert(safeDesOffset == 0, `safe des returned wrong offset: expected 0, got {safeDesOffset}`)

		local ok = pcall(Z.des, schema, truncatedBuffer, 0, false)
		assert(not ok, "unsafe des should error on incomplete data")
	end,

	["Strings and Buffers"] = function()
		local BUFFER_EQUALS = function(a: buffer, b: buffer)
			return buffer.len(a) == buffer.len(b) and buffer.tostring(a) == buffer.tostring(b)
		end

		check(Z.byte, "a")
		check(Z.str8, string.rep("a", SIZE_8))
		check(Z.str16, string.rep("b", SIZE_16))

		-- str32's 2^32-1 wire bound is unreachable in practice: Luau caps both
		-- strings and buffers at 1 GiB (string.rep and buffer.create error past
		-- 2^30), and bufferless Z.ser is further capped by the scratch buffer.
		-- Pin the exact maximum through the default path, and one past it.
		local maxDefault = buffer.len(Z.BUFFER) - 4
		check(Z.str32, string.rep("c", maxDefault))
		assert(
			not Z.ser(Z.str32, string.rep("c", maxDefault + 1)),
			"str32 past the scratch buffer capacity should fail to serialize"
		)

		-- a caller-provided buffer lifts the scratch cap: prove the u32 length
		-- prefix carries payloads larger than the default path allows
		local big = string.rep("d", 2 ^ 24)
		local bigSchema = Z.schema { Value = Z.str32 }
		local bigBuffer = buffer.create(4 + 2 ^ 24)
		local bigOffset, bigErr = Z.ser(bigSchema, { Value = big }, bigBuffer, 0)
		assert(bigOffset == 4 + 2 ^ 24, `str32 with a caller buffer failed: {bigErr}`)
		assert(Z.des(bigSchema, bigBuffer).Value == big, "str32 caller-buffer roundtrip failed")

		check(Z.buffer8, buffer.fromstring(string.rep("a", SIZE_8)), BUFFER_EQUALS)
		check(Z.buffer16, buffer.fromstring(string.rep("b", SIZE_16)), BUFFER_EQUALS)
		check(Z.buffer32, buffer.fromstring(string.rep("c", maxDefault)), BUFFER_EQUALS)
	end,

	["Tables"] = function()
		check(Z.schema({ Z.u8 }), { 1, 2, 3, 4, 5 })
		check(Z.schema({ [Z.str8] = Z.u8 }), { a = 1, b = 2 })
		check(Z.table, { nested = { deeper = { value = 1 } }, list = { 1, 2, 3 } })
		check(Z.table, {
			x = 1,
			y = "foo",
			z = true,
			Axes = Axes.new(Enum.NormalId.Top),
			BrickColor = BrickColor.Random(),
			CFrame = CFrame.new(math.random(), math.random(), math.random())
				* CFrame.Angles(math.random(2 * math.pi), math.random(2 * math.pi), math.random(2 * math.pi)),
			Color3 = Color3.fromRGB(0, 128, 255),
			ColorSequence = ColorSequence.new(Color3.new(), Color3.new(1, 1, 1)),
			DateTime = DateTime.now(),
			EnumItem = Enum.AccessoryType.Front,
			Faces = Faces.new(Enum.NormalId.Back),
			FloatCurveKey = FloatCurveKey.new(0.5, 1, Enum.KeyInterpolationMode.Cubic),
			Font = Font.fromEnum(Enum.Font.FredokaOne),
			NumberRange = NumberRange.new(0, math.pi),
			NumberSequence = NumberSequence.new(2, 3),
			Path2DControlPoint = Path2DControlPoint.new(UDim2.new()),
			PathWaypoint = PathWaypoint.new(Vector3.one, Enum.PathWaypointAction.Walk, "potato"),
			PhysicalProperties = PhysicalProperties.new(1, 1, 1, 1, 1),
			Ray = Ray.new(Vector3.zero, Vector3.one),
			Rect = Rect.new(0, 0, 100, 100),
			Region3 = Region3.new(Vector3.zero, Vector3.one),
			Region3int16 = Region3int16.new(Vector3int16.new(), Vector3int16.new(1, 1, 1)),
			RotationCurveKey = RotationCurveKey.new(1, CFrame.new(1, 1, 1), Enum.KeyInterpolationMode.Cubic),
			TweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			UDim = UDim.new(1, 1),
			UDim2 = UDim2.new(1, 1),
			Vector2 = Vector2.one,
			Vector2int16 = Vector2int16.new(1, 1),
			Vector3 = Vector3.one,
			Vector3int16 = Vector3int16.new(1, 1, 1),
		}, function(a, b)
			for k, v in a do
				if v ~= b[k] then
					warn(k, v, b[k])
					return false
				end
			end
			return true
		end)
	end,

	["Variable Length"] = function()
		-- boundary values at every varint byte-width transition
		local uints = {
			0,
			2 ^ 7 - 1,
			2 ^ 7,
			2 ^ 14 - 1,
			2 ^ 14,
			2 ^ 21 - 1,
			2 ^ 21,
			2 ^ 28 - 1,
			2 ^ 28,
			2 ^ 35 - 1,
			2 ^ 35,
			2 ^ 53,
		}
		for _, value in uints do
			check(Z.uint, value)
		end

		local ints = { 0, 1, -1, 2 ^ 6 - 1, 2 ^ 6, -2 ^ 6, -2 ^ 6 - 1, 2 ^ 13, -2 ^ 13, 2 ^ 53, -2 ^ 53 }
		for _, value in ints do
			check(Z.int, value)
		end

		assert(not Z.ser(Z.uint, -1), "uint should reject negative values")
	end,
}

local testsList = {}
for name, f in tests do
	table.insert(testsList, { name, f })
end

table.sort(testsList, function(a, b)
	return a[1] < b[1]
end)

warn("Z Test Results:")

local fail
for _, v in testsList do
	local name, f = unpack(v)
	local ok, err = pcall(f)
	-- a failing test must not leak configuration into the tests after it
	Z.TRIM_STRINGS = false
	if ok then
		print(`✅ {name}`)
	else
		warn(`❌ {name}: {err}`)
		fail = true
	end
end

if fail then
	error("One or more tests failed")
end

return "All tests passed."
