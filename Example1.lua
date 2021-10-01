-- Here's an example of a server-side code of my Turn-Based MMORPG battle system.  It's pretty complex

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local shared = ReplicatedStorage.Shared
local Signal = require(shared.Signal)
local Maid = require(shared.Maid)
local Promise = require(shared.Promise)
local Zone = require(shared.Zone)
local IsInstanceInBattle = require(shared.IsInstanceInBattle)
local BattleState = require(shared.Enums.BattleState)
local MoveService = require(shared.Services.MoveService)

local server = ServerScriptService.Server
local MoveSequenceService = require(server.Services.MoveSequenceService)

local remoteEvents = shared.RemoteEvents
local battleEvents = remoteEvents.BattleEvents

local BattleManager = {}
BattleManager.__index = BattleManager
BattleManager.ClassName = "BattleManager"

function BattleManager.new(baseBattleBackground)
	local self = setmetatable({}, BattleManager)
	self._maid = Maid.new()
	self._battleState = BattleState.None
	self._instances = {}
	self._categories = {}
	
	self.BattleBackground = baseBattleBackground:Clone()
	self.BattleBackground.Parent = Workspace
	
	self.BattleCountdownTime = 20
	
	self.InstanceAdded = Signal.new()
	self.InstanceRemoved = Signal.new()
	self.BattleStateChanged = Signal.new()
	self.BattleEnded = Signal.new()
	
	self._battleData = script.BattleData:Clone()
	self._battleData.Parent = self.BattleBackground
	
	self._battleStateValue = script.BattleState:Clone()
	self._battleStateValue.Value = self._battleState
	self._battleStateValue.Parent = self.BattleBackground
	
	self._currentMoveRunner = script.CurrentMoveRunner:Clone()
	self._currentMoveRunner.Parent = self.BattleBackground
	
	self._maid:GiveTask(self.BattleBackground)
	self._maid:GiveTask(self.InstanceAdded)
	self._maid:GiveTask(self.InstanceRemoved)
	self._maid:GiveTask(self.BattleStateChanged)
	self._maid:GiveTask(self.BattleEnded)
	
	return self
end

function BattleManager:CreateCategory(categoryName)
	self._categories[categoryName] = {}
end

function BattleManager:GetCategory(categoryName)
	return self._categories[categoryName]
end

function BattleManager:AddToCategory(categoryName, instance)
	local instanceData = self:GetInstanceData(instance)
	instanceData.Category.Value = categoryName
	
	table.insert(self._categories[categoryName], instance)
end

function BattleManager:RemoveFromCategory(categoryName, instance)
	local instanceData = self:GetInstanceData(instance)
	if instanceData then
		instanceData.Category.Value = ""
	end
	
	table.remove(self._categories[categoryName], table.find(self._categories[categoryName], instance))
end

function BattleManager:GetBattleState()
	return self._battleState
end

function BattleManager:GetBattleStateChangedSignal(battleState)
	local battleStateChangedSignal = Signal.new()
	self.BattleStateChanged:Connect(function(previousBattleState)
		if self:GetBattleState() == battleState then
			battleStateChangedSignal:Fire(previousBattleState)
		end
	end)
	
	return battleStateChangedSignal
end

function BattleManager:_setBattleState(battleState)
	local previous = self._battleState
	
	self._battleState = battleState
	self._battleStateValue.Value = battleState
	self.BattleStateChanged:Fire(previous)
end

function BattleManager:GetInstanceMoveOrder()
	return { 
		
		--[[
		In PVE:
		
		{
			getPlayers(self),
			getEnemies(self),
		},
		
		In PVP:
		
		{
			dividePlayers(self),
			getOthers(self),
		}
		
		--]]
	}
end

function BattleManager:ShouldEndBattle()
	return true
end

-- Sort of a mega-method. May want to divide it up
function BattleManager:Start()
	return Promise.defer(function()
		do
			local enterBattle = self.BattleBackground:FindFirstChild("EnterBattle")
			if enterBattle then
				local enterBattleZone = Zone.new(enterBattle)
				enterBattleZone.playerAdded:Connect(function(player)
					if self:ShouldEndBattle() then
						return
					end
					
					if IsInstanceInBattle(player) then
						return
					end
					
					self:AddInstance(player)
				end)

				enterBattleZone:initLoop()
				self._maid:GiveTask(enterBattleZone)
			end
			
			local backgroundServer = self.BattleBackground:FindFirstChild("BackgroundServer")
			if backgroundServer then
				backgroundServer.Disabled = false
			end
		end
		
		while #self:GetInstances() > 0 do
			if self:ShouldEndBattle() then
				self:Destroy()
				break
			end
			
			RunService.Heartbeat:Wait()
			
			for _, instanceData in ipairs(self._battleData:GetChildren()) do
				instanceData.ChosenMove.Value = ""
				instanceData.Targets:ClearAllChildren()
			end
			
			self:_setBattleState(BattleState.Choosing)
			
			local battleChoicePromises = table.create(3)
			
			battleChoicePromises[1] = Promise.new(function(resolve, reject, onCancel)
				local timerHeartbeat
				local function disconnectTimerHeartbeat()
					timerHeartbeat:Disconnect()
					timerHeartbeat = nil
				end
				
				onCancel(disconnectTimerHeartbeat)
				
				local currentTime = -math.huge
				local timerNumber = self.BattleCountdownTime + 1
				
				timerHeartbeat = RunService.Heartbeat:Connect(function()
					if self:GetBattleState() == BattleState.Casting then
						disconnectTimerHeartbeat()
						return
					end
					
					if timerNumber == 0 then
						disconnectTimerHeartbeat()
						resolve()
						return
					end
					
					if os.clock() - currentTime < 1 then
						return
					end
					
					timerNumber -= 1
					
					-- Still sort of decoupled from BattleService because you don't
					-- have a method that gets Players in a battle (if that makes any
					-- sense)
					for _, instance in ipairs(self:GetInstances()) do
						if instance:IsA("Player") then
							battleEvents.UpdateTimer:FireClient(instance, timerNumber)
						end
					end
					
					currentTime = os.clock()
				end)
			end)

			battleChoicePromises[2] = Promise.new(function(resolve, reject, onCancel)
				local repeatUntilMovesAndTargetsChosen
				
				local function disconnectConnection()
					repeatUntilMovesAndTargetsChosen:Disconnect()
					repeatUntilMovesAndTargetsChosen = nil
				end
				
				onCancel(disconnectConnection)
				
				repeatUntilMovesAndTargetsChosen = RunService.Heartbeat:Connect(function()
					if not self._battleData then
						return
					end
					
					local validInstanceDatas = 0
					
					for _, instanceData in ipairs(self._battleData:GetChildren()) do
						if instanceData.ChosenMove.Value == "" then
							break
						end
						
						if #instanceData.Targets:GetChildren() == 0 then
							break
						end
						
						validInstanceDatas += 1
					end
					
					if validInstanceDatas == #self._battleData:GetChildren() then
						resolve()
						disconnectConnection()
					end
				end)
				
				self._maid:GiveTask(repeatUntilMovesAndTargetsChosen)
			end)
			
			battleChoicePromises[3] = Promise.new(function(resolve, reject, onCancel)
				local checkInstances
				local function disconnectConnection()
					checkInstances:Disconnect()
					checkInstances = nil
				end
				
				onCancel(disconnectConnection)
				checkInstances = RunService.Heartbeat:Connect(function()
					if #self:GetInstances() == 1 then
						resolve()
						disconnectConnection()
					end
				end)
			end)
			
			local battleChoicePromise = Promise.race(battleChoicePromises)
			battleChoicePromise:await()
			
			if self:ShouldEndBattle() then
				-- Instead of copying code, we will use continue, which will bring
				-- the loop all the way to the beginning and the check will occur
				-- in the beginning, so no copy pasting!
				continue
			end
			
			self:_setBattleState(BattleState.Casting)
			for _, instance in ipairs(self:GetInstances()) do
				if instance:IsA("Player") then
					battleEvents.ClientBattleCasting:FireClient(instance)
				end
			end
			
			local instanceMoveOrder = self:GetInstanceMoveOrder()
			for _, instances in ipairs(instanceMoveOrder) do
				for _, instance in ipairs(instances) do
					if self:ShouldEndBattle() then
						break -- Break, go back to the top of the loop and do ShouldEndBattle check
					end
					
					local instanceData = self:GetInstanceData(instance)
					if not instanceData then
						continue
					end
					
					local move = MoveService.GetMoveFromName(instanceData.ChosenMove.Value)
					if not move then
						continue
					end
					
					if #instanceData.Targets:GetChildren() == 0 then
						continue
					end
					
					local targetInstances = {}
					for _, targetValue in ipairs(instanceData.Targets:GetChildren()) do
						local target = targetValue.Value
						if targetValue.Value:IsA("Player") then
							target = target.Character
						end
						
						table.insert(targetInstances, target)
						
						targetValue:Destroy()
						targetValue = nil
					end
					
					-- This is important or else Move Module code will break for
					-- Player characters
					local runningInstance = instance
					if runningInstance:IsA("Player") then
						runningInstance = runningInstance.Character
					end
					
					local moveSequence = MoveSequenceService.Create(move.MoveSequence)
					
					self._currentMoveRunner.Value = instanceData
					
					local moveRunServerPromise = Promise.promisify(move.RunServer)(runningInstance, targetInstances, self, moveSequence)
					moveRunServerPromise:catch(function(err)
						warn(move.Name, ".RunServer() has errored:", err)
					end)
					
					moveRunServerPromise:await()
					
					runningInstance.HumanoidRootPart.CFrame = runningInstance.HumanoidRootPart.CFrame * CFrame.Angles(0, math.rad(180), 0)
					self._currentMoveRunner.Value = nil
				end
			end
		end
	end)
end

function BattleManager:CanAddInstance(instance)
	return true
end

function BattleManager:HasInstance(instance)
	return table.find(self._instances, instance) ~= nil
end

-- Time Complexity is O(n) since there can be instances with the same name
function BattleManager:GetInstanceData(instance)
	for _, instanceData in ipairs(self._battleData:GetChildren()) do
		if instanceData.Value == instance then
			return instanceData
		end
	end
end

function BattleManager:GetInstances()
	return self._instances
end

function BattleManager:UpdateTargets(instanceData, targetsList)
	instanceData.Targets:ClearAllChildren()
	
	for _, targetName in ipairs(targetsList) do
		local targetInstanceData = self.BattleBackground.BattleData:FindFirstChild(targetName)
		if not targetInstanceData then
			continue
		end

		local target = script.Target:Clone()
		target.Name = targetName
		target.Value = targetInstanceData.Value
		target.Parent = instanceData.Targets
	end
end

function BattleManager:AddInstance(instance)
	if not BattleManager:CanAddInstance(instance) then
		return false
	end
	
	if IsInstanceInBattle(instance) then
		return false
	end
	
	if self:HasInstance(instance) then
		return false
	end
	
	local humanoidRootPart = instance:FindFirstChild("HumanoidRootPart")
	if humanoidRootPart then
		-- Stop any movement that is going on since they can be diving or rolling
		-- or jumping at that moment.
		humanoidRootPart.Velocity = Vector3.new(0, 0, 0)
	end
	
	local instanceData = script.InstanceData:Clone()
	instanceData.Name = instance.Name
	instanceData.Value = instance
	instanceData.Parent = self._battleData
	
	instanceData.Health:GetPropertyChangedSignal("Value"):Connect(function()
		if instanceData.Health.Value <= 0 then
			local character = instance
			if instance:IsA("Player") then
				character = instance.Character
			end
			
			local humanoid = character:FindFirstChildWhichIsA("Humanoid")
			if not humanoid then
				return
			end
			
			humanoid.Health = 0
			self:RemoveInstance(instance)
		end
	end)
	
	CollectionService:AddTag(instance, "InBattle")
	table.insert(self._instances, instance)
	self.InstanceAdded:Fire(instance)
	
	return true
end

function BattleManager:RemoveInstance(instance)
	if not self:HasInstance(instance) then
		return false
	end
	
	if not IsInstanceInBattle(instance) then
		return false
	end
	
	local instanceData = self:GetInstanceData(instance)
	if not instanceData then
		return false
	end
	
	instanceData:Destroy()
	instanceData = nil
	
	CollectionService:RemoveTag(instance, "InBattle")
	table.remove(self._instances, table.find(self._instances, instance))
	self.InstanceRemoved:Fire(instance)
	
	return true
end

function BattleManager:Destroy()
	self.BattleEnded:Fire()
	
	local _, nextInstance = next(self:GetInstances())
	while nextInstance do
		self:RemoveInstance(nextInstance)
		_, nextInstance = next(self:GetInstances())
		
		RunService.Heartbeat:Wait()
	end
	
	self._maid:DoCleaning()
	self._maid = nil
	
	self.BattleBackground = nil
	self._battleBackground = nil
	
	self._battleData = nil
	self._currentMoveRunner = nil
	self._battleStateValue = nil
	
	table.clear(self._instances)
	table.clear(self)
	setmetatable(self, nil)
	
	self = nil
end

return BattleManager
