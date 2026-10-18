    local BUILD = "auto-parry-1"
    local UI_SOURCE_URL = "https://raw.githubusercontent.com/yentheterrible/ui/refs/heads/main/init.lua"
    local CONFIG_ENABLED = false
    local ARRIVAL_LEAD = 0.08
    local EXTRA_EARLY = 0.02
    local MAX_WINDOW = 0.40
    local CONTACT_RADIUS = 9.5
    local HIGH_PING_THRESHOLD = 100
    local HIGH_PING_EXTRA_CAP = 60
    local PING_JITTER_EXTRA_CAP = 35
    local FAST_BALL_SPEED_THRESHOLD = 350
    local FAST_BALL_LEAD_PER_SPEED = 0.00015
    local FAST_BALL_LEAD_CAP = 0.100
    local CURVE_ACCELERATION_THRESHOLD = 120
    local MAX_CURVE_ACCELERATION = 2500
    local MAX_CURVE_PREDICTION_TIME = 0.18

    if type(loadstring) ~= "function" then
        return warn("[Havoc] This environment does not provide loadstring")
    end

    local downloaded, source = pcall(function()
        return game:HttpGet(UI_SOURCE_URL)
    end)
    if not downloaded or type(source) ~= "string" or source == "" then
        return warn("[Havoc] UI download failed:", source)
    end

    local uiChunk, compileError = loadstring(source)
    if type(uiChunk) ~= "function" then
        return warn("[Havoc] UI compile failed:", compileError)
    end

    local initialized, HavocLib = pcall(uiChunk)
    if not initialized or type(HavocLib) ~= "table" or type(HavocLib.new) ~= "function" then
        return warn("[Havoc] UI initialization failed:", HavocLib)
    end

    local previousUI = getgenv().HAVOC_UI
    if previousUI then
        local closed, closeError = pcall(function()
            if type(previousUI.SetVisible) == "function" then
                previousUI:SetVisible(false)
            elseif type(previousUI.Destroy) == "function" then
                previousUI:Destroy()
            end
        end)
        if not closed then
            warn("[Havoc] Could not close the previous UI:", closeError)
        end
    end

    local previousConnections = getgenv().HAVOC_CONNECTIONS
    if previousConnections and type(previousConnections.disconnect_all) == "function" then
        local disconnected, disconnectError = pcall(function()
            previousConnections:disconnect_all()
        end)
        if not disconnected then
            warn("[Havoc] Could not disconnect previous callbacks:", disconnectError)
        end
    end
    if getgenv().HAVOC_AICOROUTINE then
        pcall(task.cancel, getgenv().HAVOC_AICOROUTINE)
        getgenv().HAVOC_AICOROUTINE = nil
    end
    for _, leftover in ipairs(workspace:GetChildren()) do
        if leftover.Name == "HavocViz" or leftover.Name == "HavocMusic" then
            leftover:Destroy()
        end
    end

    local Connections = {}
    function Connections:disconnect(key)
        local connection = self[key]
        if connection then
            connection:Disconnect()
            self[key] = nil
        end
    end
    function Connections:disconnect_all()
        for key, connection in pairs(self) do
            if typeof(connection) ~= "function" and connection.Connected then
                connection:Disconnect()
                self[key] = nil
            end
        end
    end
    getgenv().HAVOC_CONNECTIONS = Connections

    local HttpService = game:GetService("HttpService")
    local ConfigFolder = "HavocHub"
    local ConfigStore
    if CONFIG_ENABLED
        and type(isfile) == "function"
        and type(writefile) == "function"
        and type(isfolder) == "function"
        and type(makefolder) == "function"
        and type(readfile) == "function" then
        ConfigStore = {
            Save = function(name, values)
                if not isfolder(ConfigFolder) then
                    makefolder(ConfigFolder)
                end
                writefile(ConfigFolder .. "/" .. name .. ".json", HttpService:JSONEncode(values))
                return true
            end,
            Load = function(name)
                local path = ConfigFolder .. "/" .. name .. ".json"
                if not isfile(path) then
                    return nil, "config not found"
                end
                return HttpService:JSONDecode(readfile(path))
            end,
        }
    end

    local created, UI = pcall(HavocLib.new, {
        Name = "HavocHub",
        Title = "Havoc Hub",
        Subtitle = "Auto Parry + Lobby AP",
        SettingsTab = {
            Enabled = ConfigStore ~= nil,
        },
        ConfigurationSaving = {
            Enabled = ConfigStore ~= nil,
            Store = ConfigStore,
        },
    })
    if not created or type(UI) ~= "table" or type(UI.Tab) ~= "function" then
        return warn("[Havoc] UI creation failed:", UI)
    end
    local Havoc = UI._library

    repeat
        task.wait()
    until game:IsLoaded()

    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local UserInputService = game:GetService("UserInputService")
    local VirtualInputManager = game:GetService("VirtualInputManager")
    local Workspace = game:GetService("Workspace")
    local LocalPlayer = Players.LocalPlayer
    local TrainingBalls = Workspace:WaitForChild("TrainingBalls", 10)
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local ParrySuccessAll = Remotes and Remotes:FindFirstChild("ParrySuccessAll")

    if not TrainingBalls then
        warn("[Havoc] Workspace.TrainingBalls did not load; Lobby AP will wait for it, while match Auto Parry remains available")
    end

    local AccuracySetting = 100
    local RangeMultiplier = 1
    local HighPingCompensation = true
    local BallTrajectoryDetection = true
    local SpecialAbilityDetection = false
    local DeathSlashActive = false
    local InfinityBallActive = false
    local LoggingEnabled = true
    local PingHistory = {}
    local BallStates = {}
    local PendingAttempts = {}
    local FrameTrace = {}
    local TRACE_LIMIT = 120
    local LastStepErrorAt = 0
    local StartedAt = os.clock()
    local AutoSave = false

    local function log(eventName, message)
        if LoggingEnabled then
            print(string.format(
                "[Havoc Dev][%s][+%.3fs] %s",
                eventName,
                os.clock() - StartedAt,
                message
            ))
        end
    end

    local function pushTrace(entry)
        entry.At = os.clock()
        table.insert(FrameTrace, entry)
        if #FrameTrace > TRACE_LIMIT then
            table.remove(FrameTrace, 1)
        end
    end

    local function currentPing()
        local ok, value = pcall(function()
            return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
        end)
        if ok and type(value) == "number" and value == value and value >= 0 then
            return value
        end
        local pingOk, ping = pcall(function()
            return LocalPlayer:GetNetworkPing()
        end)
        if pingOk and type(ping) == "number" and ping >= 0 then
            return ping * 1000
        end
        return 50
    end

    local function averagePing()
        if #PingHistory == 0 then
            return currentPing()
        end
        local total = 0
        for _, ping in ipairs(PingHistory) do
            total += ping
        end
        return total / #PingHistory
    end

    Connections.ping = RunService.Heartbeat:Connect(function()
        table.insert(PingHistory, 1, currentPing())
        if #PingHistory > 5 then
            table.remove(PingHistory)
        end

        local now = os.clock()
        for ball, attempts in pairs(PendingAttempts) do
            while #attempts > 0 and now - attempts[1] > 1.25 do
                local attemptedAt = table.remove(attempts, 1)
                log("parry_unconfirmed", string.format(
                    "ball=%s no_success_event_after=%.0fms",
                    ball.Parent and ball.Name or "removed",
                    (now - attemptedAt) * 1000
                ))
            end
            if #attempts == 0 then
                PendingAttempts[ball] = nil
            end
        end
    end)

    local deathBallRemote = Remotes and Remotes:FindFirstChild("DeathBall")
    if deathBallRemote and deathBallRemote:IsA("RemoteEvent") then
        Connections.death_ball_state = deathBallRemote.OnClientEvent:Connect(function(active)
            DeathSlashActive = active == true
        end)
    end

    local infinityBallRemote = Remotes and Remotes:FindFirstChild("InfinityBall")
    if infinityBallRemote and infinityBallRemote:IsA("RemoteEvent") then
        Connections.infinity_ball_state = infinityBallRemote.OnClientEvent:Connect(function(_, active)
            InfinityBallActive = active == true
        end)
    end

    local function playerVelocity(root)
        local velocity = root.AssemblyLinearVelocity
        if Vector3.new(velocity.X, 0, velocity.Z).Magnitude >= 2 then
            return velocity
        end
        local humanoid = root.Parent and root.Parent:FindFirstChildOfClass("Humanoid")
        local moveDirection = humanoid and humanoid.MoveDirection or Vector3.zero
        local horizontalDirection = Vector3.new(moveDirection.X, 0, moveDirection.Z)
        if not humanoid or horizontalDirection.Magnitude < 0.05 then
            return velocity
        end
        local predictedHorizontal = horizontalDirection.Unit * humanoid.WalkSpeed
        return Vector3.new(predictedHorizontal.X, velocity.Y, predictedHorizontal.Z)
    end

    local function solveContactTime(relativePosition, relativeVelocity, radius)
        local distanceSquared = relativePosition:Dot(relativePosition)
        local speedSquared = relativeVelocity:Dot(relativeVelocity)
        if distanceSquared <= radius * radius then
            return 0
        end
        if speedSquared <= 1e-6 then
            return nil
        end

        local linearTerm = 2 * relativePosition:Dot(relativeVelocity)
        local constantTerm = distanceSquared - radius * radius
        local discriminant = linearTerm * linearTerm - 4 * speedSquared * constantTerm
        if discriminant < 0 then
            return nil
        end

        local root = math.sqrt(discriminant)
        local firstTime = (-linearTerm - root) / (2 * speedSquared)
        if firstTime >= 0 then
            return firstTime
        end
        local secondTime = (-linearTerm + root) / (2 * speedSquared)
        return secondTime >= 0 and secondTime or nil
    end

    local function solveCurvedContactTime(relativePosition, relativeVelocity, acceleration, radius, maxTime)
        if relativePosition:Dot(relativePosition) <= radius * radius then
            return 0
        end

        local stepCount = math.clamp(
            math.ceil(relativeVelocity.Magnitude * maxTime / math.max(radius * 0.5, 1)),
            24,
            128
        )
        local previousTime = 0
        for step = 1, stepCount do
            local time = maxTime * step / stepCount
            local predictedPosition = relativePosition
                + relativeVelocity * time
                + acceleration * (0.5 * time * time)
            local gap = predictedPosition:Dot(predictedPosition) - radius * radius
            if gap <= 0 then
                local low, high = previousTime, time
                for _ = 1, 8 do
                    local middle = (low + high) * 0.5
                    local middlePosition = relativePosition
                        + relativeVelocity * middle
                        + acceleration * (0.5 * middle * middle)
                    if middlePosition:Dot(middlePosition) <= radius * radius then
                        high = middle
                    else
                        low = middle
                    end
                end
                return high
            end
            previousTime = time
        end
        return nil
    end

    local function highPingCompensation(pingMs)
        if not HighPingCompensation or pingMs < HIGH_PING_THRESHOLD then
            return 0
        end

        local extra = math.clamp((pingMs - HIGH_PING_THRESHOLD) * 0.35, 0, HIGH_PING_EXTRA_CAP)
        if #PingHistory < 3 then
            return extra
        end

        local lowest, highest = math.huge, 0
        for _, sample in ipairs(PingHistory) do
            lowest = math.min(lowest, sample)
            highest = math.max(highest, sample)
        end
        local jitterMargin = math.clamp((highest - lowest) * 0.25, 0, PING_JITTER_EXTRA_CAP)
        return extra + jitterMargin
    end

    local function timingWindow(pingMs, detectionBonus)
        local accuracyEarlyFactor = 1 + ((100 - AccuracySetting) / 99) * 0.15
        local rangeEarlyFactor = 1 + (RangeMultiplier - 1) * 0.05
        return math.clamp(
            (ARRIVAL_LEAD + EXTRA_EARLY + (pingMs + highPingCompensation(pingMs)) / 1000
                + (detectionBonus or 0)) * accuracyEarlyFactor * rangeEarlyFactor,
            0.12,
            MAX_WINDOW
        )
    end

    local function getBalls(container)
        local balls = {}
        if container then
            for _, ball in ipairs(container:GetChildren()) do
                if ball:IsA("BasePart") and ball:GetAttribute("realBall") then
                    table.insert(balls, ball)
                end
            end
        end
        return balls
    end

    local function getLobbyBalls()
        return getBalls(TrainingBalls)
    end

    local function getMatchBalls()
        return getBalls(Workspace:FindFirstChild("Balls"))
    end

    local function resetBall(ball)
        local state = BallStates[ball]
        if state then
            state.Armed = true
            state.SawRetreat = true
            state.LockoutUntil = 0
            state.LastTTC = nil
            state.LastVelocity = nil
            state.LastVelocityAt = nil
            state.Acceleration = nil
            state.DirectionChangeUntil = nil
        end
    end

    local function simulateParry()
        local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
        if isMobile and type(mouse1click) == "function" then
            mouse1click()
            return
        end
        VirtualInputManager:SendMouseButtonEvent(0, 0, 0, true, game, 0)
        task.wait()
        VirtualInputManager:SendMouseButtonEvent(0, 0, 0, false, game, 0)
    end

    local function parryCooldownActive()
        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local hotbar = playerGui and playerGui:FindFirstChild("Hotbar")
        local block = hotbar and hotbar:FindFirstChild("Block")
        local gradient = block and block:FindFirstChildOfClass("UIGradient")
        return gradient ~= nil and gradient.Offset.Y <= 0.27
    end

    local function specialAbilityReason(character, root)
        if not SpecialAbilityDetection then
            return nil
        end
        if DeathSlashActive then
            return "death_slash"
        end
        if root:FindFirstChild("SingularityCape") then
            return "singularity"
        end

        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local hotbar = playerGui and playerGui:FindFirstChild("Hotbar")
        local abilityBar = hotbar and hotbar:FindFirstChild("Ability")
        local duration = abilityBar and abilityBar:FindFirstChild("Duration")
        if not duration or not duration.Visible then
            return nil
        end

        local abilities = character:FindFirstChild("Abilities")
        local function isAbilityEnabled(name)
            local ability = abilities and abilities:FindFirstChild(name)
            if not ability then
                return false
            end
            if ability:IsA("BoolValue") then
                return ability.Value
            end
            local ok, enabled = pcall(function()
                return ability.Enabled
            end)
            return ok and enabled == true
        end

        if InfinityBallActive and isAbilityEnabled("Infinity") then
            return "infinity"
        end
        if isAbilityEnabled("Time Hole") then
            return "time_hole"
        end
        return nil
    end

    local function stepParry(mode)
        local character = LocalPlayer.Character
        local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
        if not root then
            return
        end

        local playerName = tostring(LocalPlayer)
        local now = os.clock()
        local ping = averagePing()
        local pingSeconds = ping / 1000
        local balls = mode == "lobby" and getLobbyBalls() or getMatchBalls()
        for _, ball in ipairs(balls) do
            local velocityObject = ball:FindFirstChild("zoomies")
            if not velocityObject then
                pushTrace({ Kind = "gate", Ball = ball.Name, Reason = "missing_velocity", Mode = mode })
                continue
            end

            local target = ball:GetAttribute("target")
            local state = BallStates[ball]
            if not state then
                state = {
                    Armed = true,
                    SawRetreat = true,
                    LockoutUntil = 0,
                    LastTarget = target,
                }
                BallStates[ball] = state
            end

            if state.LastTarget ~= target then
                state.LastTarget = target
                resetBall(ball)
                log("target_change", string.format(
                    "mode=%s ball=%s target=%s",
                    mode,
                    ball.Name,
                    tostring(target)
                ))
            end

            if target ~= playerName then
                state.Armed = true
                state.SawRetreat = true
                state.LockoutUntil = 0
                state.LastTTC = nil
                continue
            end

            local ballVelocity = velocityObject.VectorVelocity
            local speed = ballVelocity.Magnitude
            local fastBall = BallTrajectoryDetection and speed >= FAST_BALL_SPEED_THRESHOLD
            local directionChanged = false
            local sampleInterval = now - (state.LastVelocityAt or now)
            local ballAcceleration = Vector3.zero
            if BallTrajectoryDetection and state.LastVelocity
                and sampleInterval >= 0.005 and sampleInterval <= 0.15 then
                local observedAcceleration = (ballVelocity - state.LastVelocity) / sampleInterval
                if observedAcceleration.Magnitude > MAX_CURVE_ACCELERATION then
                    observedAcceleration = observedAcceleration.Unit * MAX_CURVE_ACCELERATION
                end
                ballAcceleration = state.Acceleration
                    and state.Acceleration:Lerp(observedAcceleration, 0.4)
                    or observedAcceleration
            end
            if BallTrajectoryDetection and state.LastVelocity and speed >= 60
                and state.LastVelocity.Magnitude >= 60 and sampleInterval <= 0.25 then
                directionChanged = ballVelocity.Unit:Dot(state.LastVelocity.Unit) <= 0.80
                if directionChanged then
                    state.DirectionChangeUntil = now + 0.18
                end
            end
            state.LastVelocity = ballVelocity
            state.LastVelocityAt = now
            state.Acceleration = ballAcceleration
            local recentDirectionChange = BallTrajectoryDetection
                and state.DirectionChangeUntil ~= nil
                and state.DirectionChangeUntil >= now
            local detectionBonus = 0
            if fastBall then
                detectionBonus += math.min(
                    (speed - FAST_BALL_SPEED_THRESHOLD) * FAST_BALL_LEAD_PER_SPEED,
                    FAST_BALL_LEAD_CAP
                )
            end
            if recentDirectionChange then
                detectionBonus += 0.035
            end

            local relativePosition = ball.Position - root.Position
            local relativeVelocity = ballVelocity - playerVelocity(root)
            local distance = relativePosition.Magnitude
            local ttc = solveContactTime(relativePosition, relativeVelocity, CONTACT_RADIUS)
            local curvedTtc
            if BallTrajectoryDetection and recentDirectionChange
                and ballAcceleration.Magnitude >= CURVE_ACCELERATION_THRESHOLD then
                curvedTtc = solveCurvedContactTime(
                    relativePosition,
                    relativeVelocity,
                    ballAcceleration,
                    CONTACT_RADIUS,
                    MAX_CURVE_PREDICTION_TIME
                )
                if curvedTtc and (not ttc or curvedTtc < ttc) then
                    ttc = curvedTtc
                end
            end
            local radialClosingSpeed = distance > 1e-3
                and -relativePosition:Dot(relativeVelocity) / distance
                or 0
            local approaching = radialClosingSpeed > 1e-3 or curvedTtc ~= nil
            if not approaching or directionChanged then
                state.SawRetreat = true
            end

            if not ttc and approaching then
                ttc = math.max(distance - CONTACT_RADIUS, 0) / math.max(relativeVelocity.Magnitude, 1)
            end
            if not approaching then
                state.LastTTC = nil
            elseif ttc and state.LastTTC and state.LastTTC <= 0.12 and ttc >= state.LastTTC + 0.10 then
                state.SawRetreat = true
            end
            state.LastTTC = ttc

            local window = timingWindow(ping, detectionBonus)
            local pingCompensation = highPingCompensation(ping)
            local baseRange = CONTACT_RADIUS + speed * 0.40 + ping / 10
            local effectiveRange = baseRange * RangeMultiplier
            local lockoutRemaining = math.max(state.LockoutUntil - now, 0)
            local inWindow = ttc ~= nil and ttc <= window and distance <= effectiveRange
            local specialReason = specialAbilityReason(character, root)
            local ready = state.Armed
                or (state.SawRetreat and lockoutRemaining <= 0)
            local cooldown = parryCooldownActive()
            local decision = not approaching and "not_approaching"
                or (not inWindow and "outside_window")
                or (specialReason and "special_" .. specialReason)
                or (not ready and "same_flight_lockout")
                or (cooldown and "game_cooldown")
                or "eligible"

            pushTrace({
                Kind = "frame",
                Ball = ball.Name,
                Distance = distance,
                Range = effectiveRange,
                Speed = speed,
                Ttc = ttc,
                CurvedTtc = curvedTtc,
                Window = window,
                PingCompensation = pingCompensation,
                FastBall = fastBall,
                DirectionChanged = recentDirectionChange,
                Mode = mode,
                Accuracy = AccuracySetting,
                RangeMultiplier = RangeMultiplier,
                Lockout = lockoutRemaining,
                Decision = decision,
            })

            if decision ~= "eligible" then
                continue
            end

            state.Armed = false
            state.SawRetreat = false
            state.LastTTC = ttc
            local retryLockout = math.clamp(0.35 + pingSeconds, 0.35, 0.60)
            if speed >= 350 or recentDirectionChange then
                retryLockout = math.clamp(0.06 + pingSeconds * 0.5, 0.06, 0.10)
            end
            state.LockoutUntil = now + retryLockout
            local sent, inputError = pcall(simulateParry)
            if not sent then
                state.Armed = true
                warn("[Havoc] " .. mode .. " parry input failed:", inputError)
                log("input_error", tostring(inputError))
                continue
            end

            local attempts = PendingAttempts[ball]
            if not attempts then
                attempts = {}
                PendingAttempts[ball] = attempts
            end
            table.insert(attempts, now)
            pushTrace({
                Kind = "attempt",
                Ball = ball.Name,
                Ttc = ttc,
                Distance = distance,
                Speed = speed,
                Mode = mode,
            })
            log("parry_attempt", string.format(
                "mode=%s ball=%s dispatch=input ttc=%.3fs window=%.3fs distance=%.1f range=%.1f speed=%.1f ping=%.1fms compensation=%.0fms fast=%s turn=%s accuracy=%d%% rangeMultiplier=%dx",
                mode,
                ball.Name,
                ttc,
                window,
                distance,
                effectiveRange,
                speed,
                ping,
                pingCompensation,
                tostring(fastBall),
                tostring(recentDirectionChange),
                AccuracySetting,
                RangeMultiplier
            ))
        end
    end

    local function clearBallState(ball)
        BallStates[ball] = nil
        PendingAttempts[ball] = nil
    end

    local function startLobbyLoop()
        if Connections.lobby_loop then
            return
        end
        local function watchTrainingBalls(folder)
            TrainingBalls = folder
            Connections:disconnect("lobby_removed")
            if folder then
                for _, ball in ipairs(getLobbyBalls()) do
                    resetBall(ball)
                end
                Connections.lobby_removed = folder.ChildRemoved:Connect(clearBallState)
            end
        end
        watchTrainingBalls(TrainingBalls)
        if not TrainingBalls then
            Connections.lobby_folder_added = Workspace.ChildAdded:Connect(function(child)
                if child.Name == "TrainingBalls" then
                    watchTrainingBalls(child)
                    Connections:disconnect("lobby_folder_added")
                end
            end)
        end
        Connections.lobby_loop = RunService.PreSimulation:Connect(function()
            local ok, err = pcall(stepParry, "lobby")
            if not ok and os.clock() - LastStepErrorAt >= 1 then
                LastStepErrorAt = os.clock()
                warn("[Havoc] Lobby parry step failed:", err)
                log("lobby_step_error", tostring(err))
            end
        end)
        log("lobby_ap", "enabled")
    end

    local function stopLobbyLoop()
        Connections:disconnect("lobby_loop")
        Connections:disconnect("lobby_removed")
        Connections:disconnect("lobby_folder_added")
        log("lobby_ap", "disabled")
    end

    local function startAutoParryLoop()
        if Connections.auto_parry_loop then
            return
        end

        local function watchMatchBalls(folder)
            Connections:disconnect("auto_parry_removed")
            if folder then
                for _, ball in ipairs(getBalls(folder)) do
                    resetBall(ball)
                end
                Connections.auto_parry_removed = folder.ChildRemoved:Connect(clearBallState)
            end
        end

        watchMatchBalls(Workspace:FindFirstChild("Balls"))
        Connections.auto_parry_folder_added = Workspace.ChildAdded:Connect(function(child)
            if child.Name == "Balls" then
                watchMatchBalls(child)
            end
        end)
        Connections.auto_parry_loop = RunService.PreSimulation:Connect(function()
            local ok, err = pcall(stepParry, "match")
            if not ok and os.clock() - LastStepErrorAt >= 1 then
                LastStepErrorAt = os.clock()
                warn("[Havoc] Auto parry step failed:", err)
                log("auto_parry_step_error", tostring(err))
            end
        end)
        log("auto_parry", "enabled")
    end

    local function stopAutoParryLoop()
        Connections:disconnect("auto_parry_loop")
        Connections:disconnect("auto_parry_folder_added")
        Connections:disconnect("auto_parry_removed")
        log("auto_parry", "disabled")
    end

    if ParrySuccessAll and ParrySuccessAll:IsA("RemoteEvent") then
        Connections.parry_ack = ParrySuccessAll.OnClientEvent:Connect(function(_, hitRoot)
            local character = LocalPlayer.Character
            local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
            if not root or hitRoot ~= root then
                return
            end
            local oldestBall, oldestAttempt
            for ball, attempts in pairs(PendingAttempts) do
                local attemptedAt = attempts[1]
                if attemptedAt and (not oldestAttempt or attemptedAt < oldestAttempt) then
                    oldestBall, oldestAttempt = ball, attemptedAt
                end
            end
            if oldestBall then
                log("parry_confirm", string.format(
                    "ball=%s ackAfter=%.1fms",
                    oldestBall.Parent and oldestBall.Name or "removed",
                    (os.clock() - oldestAttempt) * 1000
                ))
                local attempts = PendingAttempts[oldestBall]
                table.remove(attempts, 1)
                if #attempts == 0 then
                    PendingAttempts[oldestBall] = nil
                end
            else
                log("parry_confirm", "local success event without a pending attempt")
            end
        end)
    end

    local function attachDeathTrace(character)
        Connections:disconnect("death_trace")
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if not humanoid then
            humanoid = character:WaitForChild("Humanoid", 10)
        end
        if not humanoid then
            log("death_trace_error", "Humanoid did not load")
            return
        end
        Connections.death_trace = humanoid.Died:Connect(function()
            local now = os.clock()
            local emitted = 0
            local outstandingAttempts = 0
            local oldestOutstanding
            for ball, attempts in pairs(PendingAttempts) do
                for _, attemptedAt in ipairs(attempts) do
                    outstandingAttempts += 1
                    if not oldestOutstanding or attemptedAt < oldestOutstanding.At then
                        oldestOutstanding = {
                            Ball = ball,
                            At = attemptedAt,
                        }
                    end
                end
            end
            if oldestOutstanding then
                log("death_attempt_status", string.format(
                    "unconfirmed=%d oldestBall=%s oldestAttemptAgo=%.0fms",
                    outstandingAttempts,
                    oldestOutstanding.Ball.Parent and oldestOutstanding.Ball.Name or "removed",
                    (now - oldestOutstanding.At) * 1000
                ))
            else
                log("death_attempt_status", "no unconfirmed parry attempts")
            end
            log("death_trace", "recent parry frames:")
            local firstTraceIndex = math.max(1, #FrameTrace - 49)
            for index = firstTraceIndex, #FrameTrace do
                local entry = FrameTrace[index]
                if now - entry.At <= 2 and emitted < 50 then
                    if entry.Kind == "frame" then
                        log("death_frame", string.format(
                            "t=-%.3fs mode=%s ball=%s decision=%s dist=%.1f range=%.1f speed=%.1f ttc=%s window=%.3f pingComp=%.0f fast=%s turn=%s accuracy=%d rangeMultiplier=%d lockout=%.3f",
                            now - entry.At,
                            tostring(entry.Mode),
                            tostring(entry.Ball),
                            tostring(entry.Decision),
                            entry.Distance or -1,
                            entry.Range or -1,
                            entry.Speed or 0,
                            entry.Ttc and string.format("%.3f", entry.Ttc) or "nil",
                            entry.Window or 0,
                            entry.PingCompensation or 0,
                            tostring(entry.FastBall),
                            tostring(entry.DirectionChanged),
                            entry.Accuracy or AccuracySetting,
                            entry.RangeMultiplier or RangeMultiplier,
                            entry.Lockout or 0
                        ))
                    elseif entry.Kind == "attempt" then
                        log("death_frame", string.format(
                            "t=-%.3fs ball=%s attempt ttc=%s dist=%.1f speed=%.1f",
                            now - entry.At,
                            tostring(entry.Ball),
                            entry.Ttc and string.format("%.3f", entry.Ttc) or "nil",
                            entry.Distance or -1,
                            entry.Speed or 0
                        ))
                    else
                        log("death_frame", string.format(
                            "t=-%.3fs ball=%s gate=%s",
                            now - entry.At,
                            tostring(entry.Ball),
                            tostring(entry.Reason)
                        ))
                    end
                    emitted += 1
                end
            end
            if emitted == 0 then
                log("death_trace", "no recent ball frames recorded")
            end
        end)
    end

    attachDeathTrace(LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait())
    Connections.character_added = LocalPlayer.CharacterAdded:Connect(function(character)
        FrameTrace = {}
        DeathSlashActive = false
        InfinityBallActive = false
        attachDeathTrace(character)
    end)

    local function saveConfig()
        if not AutoSave then
            return
        end
        local callSucceeded, saved, message = pcall(UI.SaveConfig, UI, "default")
        if not callSucceeded then
            warn("[Havoc] Config save threw an error:", saved)
        elseif not saved then
            warn("[Havoc] Could not save config:", message)
        end
    end

    local mainTab = UI:Tab({ Name = "Main", Icon = "swords" })
    local section = mainTab:Section({
        Name = "Parry Settings",
        Description = "Shared timing, accuracy, and range settings for both parry modes.",
        Icon = "home",
    })

    local lobbyToggle
    lobbyToggle = section:Toggle({
        Flag = "LobbyAP",
        Name = "Lobby AP",
        Description = "Automatically parry balls targeting you in the lobby.",
        Default = false,
        Changed = saveConfig,
        Callback = function(enabled)
            if enabled then
                startLobbyLoop()
            else
                stopLobbyLoop()
            end
        end,
    })

    local autoSection = mainTab:Section({
        Name = "Auto Parry",
        Description = "Automatically parries balls targeting you in a live match.",
        Icon = "shield",
    })

    local autoParryToggle
    autoParryToggle = autoSection:Toggle({
        Flag = "AutoParry",
        Name = "Auto Parry",
        Description = "Parry real balls in Workspace.Balls when they target you.",
        Default = false,
        Changed = saveConfig,
        Callback = function(enabled)
            if enabled then
                startAutoParryLoop()
            else
                stopAutoParryLoop()
            end
        end,
    })

    autoSection:Keybind({
        Flag = "AutoParryKey",
        Name = "Auto Parry keybind",
        Changed = saveConfig,
        Callback = function()
            autoParryToggle:Set(not autoParryToggle.Value)
        end,
    })

    section:Keybind({
        Flag = "LobbyAPKey",
        Name = "Lobby AP keybind",
        Changed = saveConfig,
        Callback = function()
            lobbyToggle:Set(not lobbyToggle.Value)
        end,
    })

    section:Slider({
        Flag = "ParryAccuracy",
        Name = "Parry Accuracy",
        Description = "Higher settings tighten the timing; lower settings bias the parry earlier.",
        Min = 1,
        Max = 100,
        Default = 100,
        Step = 1,
        Suffix = "%",
        Changed = saveConfig,
        Callback = function(value)
            AccuracySetting = math.clamp(value, 1, 100)
        end,
    })

    section:Slider({
        Flag = "ParryRangeMultiplier",
        Name = "Parry Range",
        Description = "Expands the allowed distance and timing window from 1x to 10x.",
        Min = 1,
        Max = 10,
        Default = 1,
        Step = 1,
        Suffix = "x",
        Changed = saveConfig,
        Callback = function(value)
            RangeMultiplier = math.clamp(value, 1, 10)
        end,
    })

    section:Toggle({
        Flag = "HighPingCompensation",
        Name = "High Ping Compensation",
        Description = "Adds a capped lead and recent ping-jitter margin above 100 ms.",
        Default = true,
        Changed = saveConfig,
        Callback = function(enabled)
            HighPingCompensation = enabled
        end,
    })

    section:Toggle({
        Flag = "BallTrajectoryDetection",
        Name = "Fast / Curving Ball Detection",
        Description = "Adds up to 100 ms of fast-ball lead and predicts short curved paths after sharp turns.",
        Default = true,
        Changed = saveConfig,
        Callback = function(enabled)
            BallTrajectoryDetection = enabled
        end,
    })

    section:Toggle({
        Flag = "SpecialAbilityDetection",
        Name = "Special Ability Detection",
        Description = "Skips a parry while Death Slash, Infinity, Singularity, or Time Hole state is detected.",
        Default = false,
        Changed = saveConfig,
        Callback = function(enabled)
            SpecialAbilityDetection = enabled
        end,
    })

    section:Toggle({
        Flag = "DeveloperLogging",
        Name = "Developer Logging",
        Description = "Records parry decisions and a short death trace.",
        Default = true,
        Changed = saveConfig,
        Callback = function(enabled)
            LoggingEnabled = enabled
        end,
    })

    if ConfigStore and isfile(ConfigFolder .. "/default.json") then
        local callSucceeded, loaded, message = pcall(UI.LoadConfig, UI, "default")
        if not callSucceeded then
            warn("[Havoc] Config load threw an error:", loaded)
        elseif not loaded then
            warn("[Havoc] Could not load config:", message)
        end
    end
    AutoSave = ConfigStore ~= nil
    log("build", BUILD .. " regular+ lobby AP; capped high-ping, fast-ball, direction-change, and optional special-state detection")

    local originalSetVisible = UI.SetVisible
    UI.SetVisible = function(self, visible)
        if not visible then
            saveConfig()
            Connections:disconnect_all()
            if Havoc and type(Havoc.Destroy) == "function" then
                Havoc:Destroy()
            end
            return
        end
        if type(originalSetVisible) == "function" then
            return originalSetVisible(self, visible)
        end
    end

    getgenv().HAVOC_UI = UI
