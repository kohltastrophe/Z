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
	return true
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

	["Direct ZType"] = function()
		local ser, err = Z.ser(Z.u8, SIZE_8)
		assert(ser, `Failed to serialize u8 directly: {err}`)

		local desData, _bytesRead = Z.des(Z.u8, ser)
		assert(desData == SIZE_8, `Failed to deserialize u8 directly`)
	end,

	["Limits"] = function()
		check(Z.schema8 { Z.u8 }, table.create(SIZE_8, SIZE_8))
		check(Z.schema16 { Z.u16 }, table.create(SIZE_16, SIZE_16))
		check(Z.schema32 { Z.u32 }, table.create(SIZE_16 + 1, SIZE_32))

		local map8 = table.create(SIZE_8)
		for i = 1, SIZE_8 do
			map8[tostring(i)] = i
		end
		check(Z.schema8 { [Z.str8] = Z.u8 }, map8)

		local map16 = table.create(SIZE_16)
		for i = 1, SIZE_16 do
			map16[tostring(i)] = i
		end
		check(Z.schema16 { [Z.str8] = Z.u16 }, map16)

		local map32 = table.create(SIZE_16 + 1)
		for i = 1, SIZE_16 + 1 do
			map32[tostring(i)] = i
		end
		check(Z.schema32 { [Z.str8] = Z.u32 }, map32)
	end,

	["Nested Schemas"] = function()
		local schema = Z.schema { nested = Z.schema { value = Z.u8 } }
		local data = { nested = { value = 255 } }
		local ser, err = Z.ser(schema, data)
		assert(ser, `Failed to serialize nested schemas: {err}`)

		local desData, _bytesRead = Z.des(schema, ser)
		assert(DEEP_EQUALS(data, desData), `Failed to deserialize nested schemas`)
	end,

	["Optionals"] = function()
		check(Z.some(Z.u8), nil)
		check(Z.some(Z.u8), 123)
	end,

	["Out Of Bounds"] = function()
		assert(not Z.ser(Z.str8, string.rep("a", 256)), "str8 should fail with length 256")
		assert(not Z.ser(Z.schema8 { Z.u8 }, table.create(256, 0)), "list with 8bit length should fail with 256 items")
		assert(
			not Z.ser(Z.schema8 { [Z.u8] = Z.u8 }, table.create(256, 0)),
			"map with 8bit length should fail with 256 items"
		)
	end,

	["Primitives"] = function()
		check(Z.bool, true)
		check(Z.bool, false)
		check(Z.bools, { true, false, true })
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
		check(Z.Angle8, math.pi, function(a, b)
			return math.abs(a - b) < 2 * math.pi / 254
		end)
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
		check(
			Z.Font,
			Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.Bold, Enum.FontStyle.Italic)
		)
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
		assert(type(safeDes) == "table", `safe des should return table on incomplete data, got {typeof(safeDes)}`)
		assert(safeDesOffset == 0, `safe des returned wrong offset: expected 0, got {safeDesOffset}`)

		local ok = pcall(Z.des, schema, truncatedBuffer, 0, false)
		assert(not ok, "unsafe des should error on incomplete data")
	end,

	["Strings and Buffers"] = function()
		check(Z.byte, "a")
		check(Z.str8, string.rep("a", 2 ^ 8 - 1))
		check(Z.str16, string.rep("b", 2 ^ 16 - 1))
		check(Z.str32, string.rep("c", 2 ^ 32 - 1))
		check(Z.buffer8, buffer.fromstring(string.rep("a", 2 ^ 8 - 1)), function(a: buffer, b: buffer)
			return buffer.len(a) == buffer.len(b) and buffer.tostring(a) == buffer.tostring(b)
		end)
	end,

	["Tables"] = function()
		check(Z.schema({ Z.u8 }), { 1, 2, 3, 4, 5 })
		check(Z.schema({ [Z.str8] = Z.u8 }), { a = 1, b = 2 })
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
		check(Z.uint, 0)
		check(Z.uint, 2 ^ 7 - 1)
		check(Z.uint, 2 ^ 53)
		check(Z.int, 0)
		check(Z.int, -2 ^ 6 - 1)
		check(Z.int, -2 ^ 53)
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
