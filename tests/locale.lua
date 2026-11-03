-- Every language holds every text the code shows, and keeps its formats. Plain Lua 5.1, no build needed.
--   lua5.1 tests/locale.lua
local LOCALES = { "deDE", "esES", "esMX", "frFR", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }
-- The same word in English: nothing to translate.
local SAME = { frFR = { Options = true } }

local function read(path)
	local f = assert(io.open(path, "rb"))
	local text = f:read("*a")
	f:close()
	return text
end

-- The keys the code uses.
local used, count = {}, 0
for _, file in ipairs({ "Addon", "Options", "Plan" }) do
	for key in read("planner/" .. file .. ".lua"):gmatch('L%["(.-)"%]') do
		if not used[key] then
			used[key] = true
			count = count + 1
		end
	end
end
assert(count > 50, "no keys found: run this from the project's folder")

local function formats(text)
	local out = {}
	for f in text:gmatch("%%[%d%.]*[%a%%]") do out[#out + 1] = f end
	return table.concat(out, " ")
end
local function sample(text)
	local args = {}
	for f in text:gmatch("%%[%d%.]*[%a%%]") do
		local kind = f:sub(-1)
		if kind == "d" or kind == "f" then args[#args + 1] = 1 elseif kind == "s" then args[#args + 1] = "x" end
	end
	return text:format(unpack(args))
end

local failed = 0
local function fail(locale, why)
	failed = failed + 1
	print("FAIL " .. locale .. ": " .. why)
end
for _, locale in ipairs(LOCALES) do
	function GetLocale() return locale end
	PolestarEveryQuest = { L = {} }
	assert(loadfile("planner/Locale-" .. locale .. ".lua"))()
	local L = PolestarEveryQuest.L
	for key in pairs(used) do
		local value = L[key]
		if not value or value == "" then
			fail(locale, "no translation of: " .. key)
		else
			if value == key and not (SAME[locale] and SAME[locale][key]) then fail(locale, "still in English: " .. key) end
			if formats(value) ~= formats(key) then fail(locale, "formats differ from the English: " .. key) end
			local ok, err = pcall(sample, value)
			if not ok then fail(locale, "does not format: " .. key .. " (" .. tostring(err) .. ")") end
		end
	end
	for key in pairs(L) do
		if not used[key] then fail(locale, "the code no longer uses: " .. key) end
	end
end
-- A file for another client must leave the table alone.
function GetLocale() return "enUS" end
PolestarEveryQuest = { L = {} }
for _, locale in ipairs(LOCALES) do assert(loadfile("planner/Locale-" .. locale .. ".lua"))() end
if next(PolestarEveryQuest.L) then fail("enUS", "a language file fills the table on an English client") end
print(failed == 0 and ("locale: all passed, " .. count .. " texts in " .. #LOCALES .. " languages") or ("locale: " .. failed .. " failed"))
os.exit(failed == 0 and 0 or 1)
