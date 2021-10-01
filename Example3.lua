-- Fuzzy searching, so pretty much Google on roblox.

local FuzzySearch = {}

local function getLevenshteinDistance(string1, string2)
	if string1 == string2 then
		return 0
	end

	local length1 = utf8.len(string1)
	local length2 = utf8.len(string2)

	if length1 == 0 then
		return length2
	elseif length2 == 0 then
		return length1
	end

	local matrix = {} -- Would love to use table.create for this, but it starts at 0.
	for index = 0, length1 do
		matrix[index] = {[0] = index}
	end

	for index = 0, length2 do
		matrix[0][index] = index
	end

	local index = 1
	local indexSub1

	for _, code1 in utf8.codes(string1) do
		local jndex = 1
		local jndexSub1

		for _, code2 in utf8.codes(string2) do
			local cost = code1 == code2 and 0 or 1
			indexSub1 = index - 1
			jndexSub1 = jndex - 1

			matrix[index][jndex] = math.min(matrix[indexSub1][jndex] + 1, matrix[index][jndexSub1] + 1, matrix[indexSub1][jndexSub1] + cost)
			jndex += 1
		end

		index += 1
	end

	return matrix[length1][length2]
end

function FuzzySearch.search(items, query)
	local distanceList = {}

	for _, item in ipairs(items) do
		table.insert(distanceList, {
			distance = getLevenshteinDistance(string.lower(item), string.lower(query)),
			item = item,
		})
	end

	table.sort(distanceList, function(a, b)
		return a.distance < b.distance
	end)

	local matchedItems = table.create(#distanceList)
	for itemIndex, itemInfo in ipairs(distanceList) do
		matchedItems[itemIndex] = itemInfo.item
	end

	return matchedItems
end

return FuzzySearch
