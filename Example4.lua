-- This is a ModuleScript that manages data.  It covers 99% of data errors.  Also includes GameAnalytics to get data from players to better understand
-- the game and what players like or dislike.  This could be very useful for Piggy: Intercity.

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local remoteFunctions = ReplicatedStorage.RemoteFunctions
local remoteEvents = ReplicatedStorage.RemoteEvents

local modules = ReplicatedStorage.Modules
local Promise = require(modules.Promise)
local Items = require(modules.Roulette.Items)
local Rarities = require(modules.Roulette.Rarities)
local Skins = require(modules.Shop.Skins)

local serverModules = ServerScriptService.Modules
local ProfileService = require(serverModules.ProfileService)
local GameAnalytics = require(serverModules.GameAnalytics)
local Roulette = require(serverModules.Roulette)

local gameProfileStore = ProfileService.GetProfileStore("PlayerData", {
	Coins = 0,
	CollectedItems = 0,
	CollectedScraps = 0,
	EquippedSkin = 1,
	EquippedTrap = 1,
	
	Settings = {
		HardMode = false,
		ShowFriendlyItems = true,
		LowDetail = false,
		ColorBlindMode = false,
		SpeedrunMode = false,
	},
	
	PersonalBests = {
		--[mapName] = personBest,
	},
	
	PurchasedSkins = { 1, },
	PurchasedTraps = { 1, },
	PurchasedGamepasses = { },
	
	CollectedEyesList = { },
	CollectedScrapsList = { },
})

local dataLoadedBindable = Instance.new("BindableEvent")

local function coinProduct(coins)
	return function(profile, userId)
		profile.Data.Coins += coins
		
		GameAnalytics:addResourceEvent(userId, {
			flowType = GameAnalytics.EGAResourceFlowType.Source,
			currency = "Coins",
			amount = coins,
			itemType = "IAP", --> in app purchase
			itemId = "Coins" .. tostring(coins),
		})
	end
end

local itemTypeProcessors = {
	Coins = function(rouletteItem, profile)
		local coinsRewarded = tonumber(string.match(rouletteItem.name, "%d+"))
		profile.Data.Coins += coinsRewarded
		
		return {
			rewardText = string.format(
				"You earned %d coins!",
				coinsRewarded
			),
		}
	end,
	
	Skin = function(rouletteItem, profile)
		local skinName = rouletteItem.name
		local skin = Skins[skinName]
		if not skin then
			return
		end
		
		if table.find(profile.Data.PurchasedSkins, skin.Id) then
			profile.Data.Coins += 100
			
			return {
				rewardText = string.format(
					"You got %s [%s], but since you own it already, you earned %d coins!",
					rouletteItem.name,
					rouletteItem.rarityType,
					100
				),
			}
		else
			table.insert(profile.Data.PurchasedSkins, skin.Id)
			
			return {
				rewardText = string.format(
					"You earned %s [%s]!",
					rouletteItem.name,
					rouletteItem.rarityType
				),
			}
		end
	end,
}

local DataManager = {}
DataManager.DataLoaded = dataLoadedBindable.Event
DataManager.Marketplace = { 
	Products = {
		-- [developerProductId] = function(profile, userId, player)
		
		[1173685304] = coinProduct(50),
		[1173685382] = coinProduct(100),
		[1173685465] = coinProduct(500),
		[1173685544] = coinProduct(1000),
		[1173685596] = coinProduct(5000),
		
		[1205157457] = function(profile, userId, player)
			local rouletteItem = Roulette.getRouletteItem(Items, Rarities)
			local processor = itemTypeProcessors[rouletteItem.itemType]
			if not processor then
				return
			end
			
			local processInfo = processor(rouletteItem, profile)
			remoteEvents.Roulette.RouletteSpinPurchased:FireClient(player, rouletteItem, processInfo)
		end,
	},
	
	PurchaseIdLog = 50, -- Store this amount of purchase id's in MetaTags;
	-- This value must be reasonably big enough so the player would not be able
	-- to purchase products faster than individual purchases can be confirmed.
	-- Anything beyond 30 should be good enough.
}

local profiles = {}

function DataManager.GetProfile(player)
	local profile = profiles[player]
	if profile then
		return profile
	end
end

function DataManager.GetProfileAsync(player)
	-- Yields until a Profile linked to a player is loaded or the player leaves
	local profile = DataManager.GetProfile(player)
	while profile == nil and player:IsDescendantOf(Players) == true do
		RunService.Heartbeat:Wait()
		profile = DataManager.GetProfile(player)
	end
	
	return profile
end

function DataManager.GetProfiles()
	return profiles
end

function DataManager.Marketplace.PurchaseIdCheckAsync(profile, purchaseId, grantProductCallback) --> Enum.ProductPurchaseDecision
	-- Yields until the purchaseId is confirmed to be saved to the profile or the profile is released

	if not profile:IsActive() then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	else
		local localPurchaseIds = profile.MetaData.MetaTags.ProfilePurchaseIds
		if localPurchaseIds == nil then
			localPurchaseIds = {}
			profile.MetaData.MetaTags.ProfilePurchaseIds = localPurchaseIds
		end

		-- Granting product if not received:

		if table.find(localPurchaseIds, purchaseId) == nil then
			while #localPurchaseIds >= DataManager.Marketplace.PurchaseIdLog do
				table.remove(localPurchaseIds, 1)
			end
			
			table.insert(localPurchaseIds, purchaseId)
			task.spawn(grantProductCallback)
		end

		-- Waiting until the purchase is confirmed to be saved:

		local result = nil

		local function checkLatestMetaTags()
			local savedPurchaseIds = profile.MetaData.MetaTagsLatest.ProfilePurchaseIds
			if savedPurchaseIds ~= nil and table.find(savedPurchaseIds, purchaseId) ~= nil then
				result = Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end

		checkLatestMetaTags()

		local releaseConnection = profile:ListenToRelease(function()
			result = result or Enum.ProductPurchaseDecision.NotProcessedYet
		end)

		local metaTagsConnection = profile.MetaTagsUpdated:Connect(function()
			checkLatestMetaTags()
		end)

		while result == nil do
			RunService.Heartbeat:Wait()
		end

		releaseConnection:Disconnect()
		metaTagsConnection:Disconnect()

		return result
	end
end

function DataManager.Marketplace.GrantProduct(player, productId)
	-- We shouldn't yield during the product granting process!
	local profile = profiles[player]
	local productFunction = DataManager.Marketplace.Products[productId]
	if productFunction ~= nil then
		productFunction(profile, player.UserId, player)
	else
		warn("ProductId " .. tostring(productId) .. " has not been defined in Products table")
	end
end

-- Async so that you the user knows that it is a yielding function
function DataManager.Marketplace.PlayerOwnsGamepassAsync(userId, gamepassId)
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return false
	end

	local profile = DataManager.GetProfileAsync(player)
	if not profile then
		return
	end
	
	if table.find(profile.Data.PurchasedGamepasses, gamepassId) then
		return true
	end

	local ownsGamepass

	-- Retry because (maybe...), the first request may fail!
	Promise.retry(
		function()
			local ownsGamepassSuccess, _ = pcall(function()
				ownsGamepass = MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamepassId)
			end)

			if not ownsGamepassSuccess then
				ownsGamepass = false
			end

		end,
		10
	):await()

	return ownsGamepass
end

local function processReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)

	if player == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local profile = DataManager.GetProfile(player)
	if profile ~= nil then
		return DataManager.Marketplace.PurchaseIdCheckAsync(
			profile,
			receiptInfo.PurchaseId,
			function()
				DataManager.Marketplace.GrantProduct(player, receiptInfo.ProductId)
			end
		)
	else
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
end

function DataManager.Init()
	function remoteFunctions.Data.GetPlayerData.OnServerInvoke(player)
		local profile = DataManager.GetProfileAsync(player)
		if not profile then
			return
		end
		
		return profile.Data
	end
	
	function remoteFunctions.Data.GetDataProperties.OnServerInvoke(player, ...)
		local profile = DataManager.GetProfileAsync(player)
		if not profile then
			return
		end
		
		local properties = {}
		local propertyNames = table.pack(...)
		
		for _, propertyName in ipairs(propertyNames) do
			properties[propertyName] = profile.Data[propertyName]
		end
		
		return properties
	end
	
	function remoteFunctions.Data.PlayerOwnsGamepass.OnServerInvoke(_, userId, gamepassId)
		return DataManager.Marketplace.PlayerOwnsGamepassAsync(userId, gamepassId)
	end
	
	local function onPlayerAdded(player)
		local profile = gameProfileStore:LoadProfileAsync(
			"Player_" .. player.UserId,
			"ForceLoad"
		)

		if profile then
			profile:Reconcile()
			profile:ListenToRelease(function()
				profiles[player] = nil
				player:Kick()
			end)

			if player:IsDescendantOf(Players) then
				profiles[player] = profile
				dataLoadedBindable:Fire(player, profile.Data)
			else
				profile:Release()
			end
		else
			player:Kick("Your data did not load. Rejoin game!")
		end
	end
	
	local function onPlayerRemoving(player)
		local profile = profiles[player]
		if profile then
			profile:Release()
		end
	end
	
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end
	
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamepassId, wasPurchased)
		if not wasPurchased then
			return
		end
		
		local profile = DataManager.GetProfile(player)
		if not profile then
			return
		end
		
		if not profile:IsActive() then
			return
		end
		
		if table.find(profile.Data.PurchasedGamepasses, gamepassId) then
			return
		end
		
		table.insert(profile.Data.PurchasedGamepasses, gamepassId)
	end)
	
	ProfileService.CorruptionSignal:Connect(function(profileStoreName, profileKey)
		local userId = string.split(profileKey, "Player_")[1]
		
		GameAnalytics:addErrorEvent(tonumber(userId), {
			severity = GameAnalytics.EGAErrorSeverity.critical,
			message = "ProfileService.CorruptionSignal fired!! BAD NEWS!!!",
		})
	end)
	
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return DataManager
