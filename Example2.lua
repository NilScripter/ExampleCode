-- A cutscene util, storing helper functions for cutscenes inside of a ModuleScript.  It's part of TLB's Cutscene Creator

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")

local skinObjects = ReplicatedStorage.SkinObjects

local modules = ReplicatedStorage.Modules
local Serializer = require(modules.Serializer)
local Promise = require(modules.Promise)
local PrettyPrint = require(modules.PrettyPrint)

local serverModules = ServerScriptService.Modules
local DataManager = require(serverModules.DataManager)

local CutsceneUtil = {}

function CutsceneUtil.getSerializedInstance(placedObject, replicationData, rootMover)
	local serializedInstance = {
		Name = placedObject.Name,
		ExtraPlacementData = Serializer.serializeList(replicationData),
		Attributes = Serializer.serializeList(placedObject:GetAttributes()),
	}

	if rootMover then
		serializedInstance.CFrame = Serializer.serializeDataType(rootMover.CFrame)
	end

	return serializedInstance
end

function CutsceneUtil.getSlot(player, currentCutscenePlot)
	local profile = DataManager.GetProfile(player)
	if not profile then
		return
	end

	local editingSlot = tonumber(currentCutscenePlot.CutscenePlotSettings:GetAttribute("SlotEditing"))
	local slot = profile.Data.Slots[editingSlot]
	if not slot then
		return
	end
	
	return slot
end

function CutsceneUtil.getInstancesFromSlot(slot, cutsceneObjectType)
	return slot.Instances[cutsceneObjectType .. "s"]
end

function CutsceneUtil.getSerializedInstanceIndexFromName(slot, cutsceneObjectType, cutsceneObjectName)
	for index, instance in ipairs(CutsceneUtil.getInstancesFromSlot(slot, cutsceneObjectType)) do
		if instance.Name == cutsceneObjectName then
			return index
		end
	end
end

function CutsceneUtil.placeCutsceneObjectNoLoadSave(player, cutsceneObjectType, cutsceneObjectCFrame, replicationData)
	local currentCutscenePlot = player.CurrentCutscenePlot.Value
	if not currentCutscenePlot then
		return
	end
	
	local cutsceneModule = modules.CutsceneObjects:FindFirstChild(tostring(cutsceneObjectType))
	if not cutsceneModule then
		return
	end
	
	cutsceneModule = require(cutsceneModule)
	
	local placedObject = cutsceneModule.OnPlaced(currentCutscenePlot, cutsceneObjectCFrame, replicationData, player)
	if not placedObject then
		return
	end

	local owner = Instance.new("ObjectValue")
	owner.Name = "Owner"
	owner.Parent = placedObject

	if placedObject:IsA("BasePart") or placedObject:IsA("Model") then
		local selectClickDetector = Instance.new("ClickDetector")
		selectClickDetector.Name = "SelectClickDetector"
		selectClickDetector.MaxActivationDistance = math.huge
		selectClickDetector.CursorIcon = "rbxassetid://532132767"
		selectClickDetector.Parent = placedObject
		
		CollectionService:AddTag(selectClickDetector, "_SelectClickDetector")

		local ownerBillboardGui = Instance.new("BillboardGui")
		ownerBillboardGui.Name = "OwnerBillboardGui"
		ownerBillboardGui.ExtentsOffset = Vector3.new(-2, 1.52, 0)
		ownerBillboardGui.Adornee = placedObject
		ownerBillboardGui.LightInfluence = 0
		ownerBillboardGui.Size = UDim2.fromScale(2, 2)

		local ownerImage = Instance.new("ImageLabel")
		ownerImage.Name = "OwnerImage"
		ownerImage.BackgroundTransparency = 1
		ownerImage.Size = UDim2.fromScale(1, 1)
		ownerImage.Image = "rbxassetid://0"
		ownerImage.Parent = ownerBillboardGui

		ownerBillboardGui.Parent = placedObject

		owner:GetPropertyChangedSignal("Value"):Connect(function()
			if owner.Value then
				local getUserThumbnailAsync = Promise.retry(Players.GetUserThumbnailAsync, 10,
					Players,
					owner.Value.UserId,
					Enum.ThumbnailType.HeadShot,
					Enum.ThumbnailSize.Size100x100
				)

				getUserThumbnailAsync:catch(function()
					ownerImage.Image = "rbxasset://textures/ui/GuiImagePlaceholder.png"
				end)

				getUserThumbnailAsync:andThen(function(content)
					ownerImage.Image = content
				end)
			else
				ownerImage.Image = "rbxassetid://0"
			end
		end)
	end

	CollectionService:AddTag(placedObject, "CutsceneObject")
	
	local function onAttributeChanged(attributeName)
		local slot = CutsceneUtil.getSlot(player, currentCutscenePlot)
		if not slot then
			return
		end

		local serializedInstance = CutsceneUtil.getInstancesFromSlot(slot, cutsceneObjectType)[CutsceneUtil.getSerializedInstanceIndexFromName(slot, cutsceneObjectType, placedObject.Name)]
		if not serializedInstance then
			return
		end

		local attributeValue = placedObject:GetAttribute(attributeName)
		serializedInstance.Attributes[attributeName] = Serializer.serializeDataType(attributeValue) or attributeValue
	end
	
	for attributeName, _ in pairs(placedObject:GetAttributes()) do
		coroutine.wrap(onAttributeChanged)(attributeName)
	end
	
	placedObject.AttributeChanged:Connect(onAttributeChanged)
	
	local previousName = placedObject.Name
	local function onNameChanged()
		local plotOwner = Players:GetPlayerByUserId(currentCutscenePlot.CutscenePlotSettings:GetAttribute("OwnerUserId"))
		if not plotOwner then
			return
		end

		local slot = CutsceneUtil.getSlot(plotOwner, currentCutscenePlot)
		if not slot then
			return
		end

		local serializedInstance = CutsceneUtil.getInstancesFromSlot(slot, cutsceneObjectType)[CutsceneUtil.getSerializedInstanceIndexFromName(slot, cutsceneObjectType, previousName)]
		if not serializedInstance then
			return
		end

		serializedInstance.Name = placedObject.Name
		previousName = serializedInstance.Name
	end
	
	coroutine.wrap(onNameChanged)()
	placedObject:GetPropertyChangedSignal("Name"):Connect(onNameChanged)
	
	local rootMover = cutsceneModule.GetRootMover(currentCutscenePlot, placedObject.Name)
	if rootMover then
		local function onCFrameChanged()
			local plotOwner = Players:GetPlayerByUserId(currentCutscenePlot.CutscenePlotSettings:GetAttribute("OwnerUserId"))
			if not plotOwner then
				return
			end

			local slot = CutsceneUtil.getSlot(plotOwner, currentCutscenePlot)
			if not slot then
				return
			end

			local serializedInstance = CutsceneUtil.getInstancesFromSlot(slot, cutsceneObjectType)[CutsceneUtil.getSerializedInstanceIndexFromName(slot, cutsceneObjectType, placedObject.Name)]
			if not serializedInstance then
				return
			end

			if not rootMover then
				return
			end
			
			serializedInstance.CFrame = Serializer.serializeDataType(rootMover.CFrame)
			print("Update serializedInstance.CFrame:", serializedInstance.CFrame)
		end
		
		coroutine.wrap(onCFrameChanged)()
		rootMover:GetPropertyChangedSignal("CFrame"):Connect(onCFrameChanged)
	end
	
	SoundService.Place:Play()
	return placedObject
end

function CutsceneUtil.placeCutsceneObject(player, cutsceneObjectType, cutsceneObjectCFrame, replicationData)
	if not player:GetAttribute("CanEditCutscene") then
		return
	end
	
	local currentCutscenePlot = player.CurrentCutscenePlot.Value
	if not currentCutscenePlot then
		return
	end
	
	local plotOwner = Players:GetPlayerByUserId(currentCutscenePlot.CutscenePlotSettings:GetAttribute("OwnerUserId"))
	if not plotOwner then
		return
	end
	
	local placedObject = CutsceneUtil.placeCutsceneObjectNoLoadSave(player, cutsceneObjectType, cutsceneObjectCFrame, replicationData)
	if not placedObject then
		return
	end
	
	local currentCutscenePlot = player.CurrentCutscenePlot.Value
	local slot = CutsceneUtil.getSlot(plotOwner, currentCutscenePlot)
	if not slot then
		return
	end

	local cutsceneModule = require(modules.CutsceneObjects[cutsceneObjectType])
	local rootMover = cutsceneModule.GetRootMover(currentCutscenePlot, placedObject.Name)
	local serializedInstance = CutsceneUtil.getSerializedInstance(placedObject, replicationData, rootMover)
	
	local slotInstances = slot.Instances[cutsceneObjectType .. "s"]
	table.insert(slotInstances, serializedInstance)
	
	return placedObject
end

function CutsceneUtil.createCharacterModel(characterData)
	local baseCharacterModel = script.Dummy:Clone()
	baseCharacterModel.Name = characterData.Name
	
	if characterData.Head ~= "" then
		local baseHead = skinObjects.Heads:FindFirstChild(characterData.Head)
		if baseHead then
			local head = baseHead:Clone()
			head.Name = "HeadModel"
			head.Parent = baseCharacterModel
			
			head:PivotTo(baseCharacterModel.Head.CFrame)
			head.MainPart.WeldConstraint.Part0 = head.MainPart
			head.MainPart.WeldConstraint.Part1 = baseCharacterModel.Head

			baseCharacterModel.Head.Transparency = 1
		end
	end

	if characterData.Package ~= "" then
		(function()
			local basePackageFolder = skinObjects.Packages:FindFirstChild(characterData.Package)
			if not basePackageFolder then
				return
			end

			for _, child in ipairs(baseCharacterModel:GetDescendants()) do
				if not child:IsA("CharacterMesh") then
					continue
				end

				child:Destroy()
			end

			for _, baseCharacterMesh in ipairs(basePackageFolder:GetChildren()) do
				local characterMesh = baseCharacterMesh:Clone()
				characterMesh.Parent = baseCharacterModel

				for _, child in ipairs(characterMesh:GetChildren()) do
					local childInfo = string.split(child.Name, "_")
					local bodyPartName = childInfo[1]
					
					local correspondingBodyPart = baseCharacterModel:FindFirstChild(bodyPartName)
					if not correspondingBodyPart then
						continue
					end
					
					child.Parent = correspondingBodyPart

					local skinObjectName = childInfo[2]
					if not characterData[skinObjectName .. "Color"] then
						continue
					end
					
					child.Color3 = Serializer.Color3.deserialize(characterData[skinObjectName .. "Color"])
				end
			end
		end)()
	end

	-- I honestly don't feel like converting turning if ... then return end
	-- to nested if statements
	if characterData.Shirt ~= "" then
		(function()
			local clothingTypeFolder = skinObjects:FindFirstChild("Shirts")
			if not clothingTypeFolder then
				return
			end

			local baseClothing = clothingTypeFolder:FindFirstChild(characterData.Shirt)
			if not baseClothing then
				return
			end

			local currentClothing = baseCharacterModel:FindFirstChild("Shirt")
			if currentClothing then
				currentClothing:Destroy()
				currentClothing = nil
			end

			local bodyClothing = baseClothing:Clone()
			bodyClothing.Name = "Shirt"
			bodyClothing.Color3 = Serializer.Color3.deserialize(characterData.ShirtColor)
			bodyClothing.Parent = baseCharacterModel
		end)()
	end

	if characterData.Pants ~= "" then
		(function()
			local clothingTypeFolder = skinObjects:FindFirstChild("Pants")
			if not clothingTypeFolder then
				return
			end

			local baseClothing = clothingTypeFolder:FindFirstChild(characterData.Pants)
			if not baseClothing then
				return
			end

			local currentClothing = baseCharacterModel:FindFirstChild("Pants")
			if currentClothing then
				currentClothing:Destroy()
				currentClothing = nil
			end

			local bodyClothing = baseClothing:Clone()
			bodyClothing.Name = "Pants"
			bodyClothing.Color3 = Serializer.Color3.deserialize(characterData.PantsColor)
			bodyClothing.Parent = baseCharacterModel
		end)()
	end

	if characterData.IdleAnimation ~= "" then
		(function()
			local animationTypeFolder = skinObjects:FindFirstChild("IdleAnimations")
			if not animationTypeFolder then
				return
			end

			local baseAnimation = animationTypeFolder:FindFirstChild(characterData.IdleAnimation)
			if not baseAnimation then
				return
			end

			local animationAsset = baseCharacterModel.Animations:FindFirstChild("Idle")
			if not animationAsset then
				return
			end

			animationAsset.AnimationId = baseAnimation.AnimationId
		end)()
	end

	if characterData.WalkAnimation ~= "" then 
		(function()
			local animationTypeFolder = skinObjects:FindFirstChild("WalkAnimations")
			if not animationTypeFolder then
				return
			end

			local baseAnimation = animationTypeFolder:FindFirstChild(characterData.WalkAnimation)
			if not baseAnimation then
				return
			end

			local animationAsset = baseCharacterModel.Animations:FindFirstChild("Walk")
			if not animationAsset then
				return
			end

			animationAsset.AnimationId = baseAnimation.AnimationId
		end)()
	end
	
	local skinColorProperties = { "HeadColor3", "LeftArmColor3", "RightArmColor3", "RightLegColor3", "TorsoColor3", "LeftLegColor3", }
	local colorSubjectClassToInfoMap = {
		Decal = {
			Properties = { "Color3", },
		}
	}
	
	for _, descendant in ipairs(baseCharacterModel:GetDescendants()) do
		local descendantInfo = string.split(descendant.Name, "_")
		local skinObjectName = descendantInfo[2]
		if not skinObjectName then
			continue
		end
		
		local colorSubject = skinObjectName .. "Color"
		if not characterData[colorSubject] then
			continue
		end

		local classInfo = colorSubjectClassToInfoMap[descendant.ClassName]
		if not classInfo then
			continue
		end

		for _, propertyName in ipairs(classInfo.Properties) do
			descendant[propertyName] = Serializer.Color3.deserialize(characterData[colorSubject])
		end
	end
	
	for _, skinColorProperty in ipairs(skinColorProperties) do
		baseCharacterModel["Body Colors"][skinColorProperty] = Serializer.Color3.deserialize(characterData.SkinColor)
	end
	
	local speakerColor = characterData.SpeakerColor or Color3.fromRGB(255, 255, 255)
	baseCharacterModel:SetAttribute("SpeakerColor", Serializer.Color3.deserialize(speakerColor))
	
	baseCharacterModel.HumanoidRootPart.Anchored = false
	baseCharacterModel.HumanoidRootPart.Transparency = 1
	
	return baseCharacterModel
end

return CutsceneUtil
