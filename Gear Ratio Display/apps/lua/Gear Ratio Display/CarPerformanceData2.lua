local json = require("json")

local M = {}

local function readFile(filePath)
    local ifp = io.open(filePath, "r")

    if not ifp then
        return nil
    end

    local contents = ifp:read("a")
    ifp:close()

    return contents
end

--- Only construct once per car or when the setup changes, not every frame
---@param vehicle ac.StateCar
---@param cPhys ac.StateCarPhysics
function M:new(vehicle, cPhys)
    local brokenEngineINI = true
    local idleRPM         = 0
    local maxRPM          = vehicle.rpmLimiter
    local turboData       = {}
    local torqueCurve     = nil

    -- Reading engine data

    local engineINI = ac.INIConfig.carData(vehicle.index, "engine.ini")

    if table.nkeys(engineINI.sections) > 0 then
        brokenEngineINI = false

        torqueCurve = ac.DataLUT11.carData(vehicle.index, engineINI:get("HEADER", "POWER_CURVE", "power.lut")) -- engineINI:tryGetLut("HEADER", "POWER_CURVE")

        if torqueCurve then
            torqueCurve.useCubicInterpolation = false
            torqueCurve.extrapolate           = true
        end

        idleRPM = engineINI:get("ENGINE_DATA", "MINIMUM", 900)
        maxRPM  = math.min(((vehicle.rpmLimiter and vehicle.rpmLimiter ~= 0) and vehicle.rpmLimiter or engineINI:get("ENGINE_DATA", "LIMITER", 99999)), engineINI:get("DAMAGE", "RPM_THRESHOLD", 99999))

        if maxRPM == 99999 then
            maxRPM = ((vehicle.rpmLimiter > 0) and vehicle.rpmLimiter or 7000)
        end

        -- Reading turbo data
        for i = 0, 9, 1 do
            local maxBoost    = engineINI:get("TURBO_" .. i, "MAX_BOOST", 0)
            local wasteGate   = engineINI:get("TURBO_" .. i, "WASTEGATE", 0)
            local referenceRPM = engineINI:get("TURBO_" .. i, "REFERENCE_RPM", -1)
            local gamma        = engineINI:get("TURBO_" .. i, "GAMMA", -1)

            if referenceRPM ~= -1 and gamma ~= -1 then
                local ctrl = ac.INIConfig.carData(vehicle.index, "ctrl_turbo" .. i .. ".ini")
                local hasControllerFile = ctrl and table.nkeys(ctrl.sections) > 0
                local controllers = {}

                if hasControllerFile then
                    for j = 0, 9, 1 do
                        local controllerInput   = ctrl:get("CONTROLLER_" .. j, "INPUT", "")
                        local controllerCombine = ctrl:get("CONTROLLER_" .. j, "COMBINATOR", "")
                        local controllerLUT     = ctrl:tryGetLut("CONTROLLER_" .. j, "LUT")

                        if string.len(controllerInput) > 0 and string.len(controllerCombine) > 0 and controllerLUT then
                            controllerLUT.useCubicInterpolation = true -- this is correct here
                            controllerLUT.extrapolate = true

                            table.insert(controllers, {
                                input      = string.upper(controllerInput),
                                combinator = string.upper(controllerCombine),
                                LUT        = controllerLUT,
                                upLimit    = ctrl:get("CONTROLLER_" .. j, "UP_LIMIT", math.NaN),
                                downLimit  = ctrl:get("CONTROLLER_" .. j, "DOWN_LIMIT", math.NaN)
                            })
                        end
                    end
                end

                table.insert(turboData, {
                    maxBoost        = maxBoost,
                    wasteGate       = wasteGate,
                    referenceRPM    = referenceRPM,
                    gamma           = gamma,
                    controllers     = controllers,
                    hasControllers  = hasControllerFile
                })
            end
        end
    end

    local drivetrainINI  = ac.INIConfig.carData(vehicle.index, "drivetrain.ini")
    local defaultShiftUp = drivetrainINI:get("AUTO_SHIFTER", "UP", math.lerp(idleRPM, maxRPM, 0.8))

    local uiTorqueCurveAvailable = false

    if vehicle.mgukDeliveryCount ~= 0 and not brokenEngineINI then

        local jsonContent = readFile(ac.getFolder(ac.FolderID.ContentCars) .. "\\" .. vehicle:id() .. "\\ui\\ui_car.json")

        if type(jsonContent) == "string" then
            jsonContent = jsonContent:gsub("[\r\n\t]", "")
        end

        local uiDataAvailable, parsedUIData = pcall(json.decode, jsonContent)

        local uiTorqueLut = ac.DataLUT11()
        local uiTorqueBad = false
        local uiMaxRPM = 0
        local uiMinRPM = 99999
        local uiMaxPower = 0

        if uiDataAvailable and type(parsedUIData) == "table" and type(parsedUIData["torqueCurve"]) == "table" then
            for _, entry in ipairs(parsedUIData["powerCurve"]) do
                if type(entry) ~= "table" then
                    uiTorqueBad = true
                    break
                end

                local r = entry[1]
                local p = entry[2]
                if type(p) == "string" then
                    p = tonumber(p)
                end
                if type(p) ~= "number" then
                    uiTorqueBad = true
                    break
                end
                if type(r) == "string" then
                    r = tonumber(r)
                end
                if type(r) ~= "number" then
                    uiTorqueBad = true
                    break
                end

                p = p * 1.16 -- rough compensation to match the range that the proper method would return
                local t = p * 5252.0 / r

                if r < uiMinRPM then
                    uiMinRPM = r
                end

                if r > uiMaxRPM then
                    uiMaxRPM = r
                end

                if p > uiMaxPower then
                    uiMaxPower = p
                end

                uiTorqueLut:add(r, t)
            end
        end

        if uiDataAvailable and not uiTorqueBad and uiMinRPM < math.lerp(idleRPM, maxRPM, 0.33) and uiMaxRPM > maxRPM * 0.995 then
            uiTorqueLut.useCubicInterpolation = false
            uiTorqueLut.extrapolate = true
            torqueCurve = uiTorqueLut
            uiTorqueCurveAvailable = true
            ac.log("Using UI power curve")
        end
    end

    self.__index = self

    return setmetatable({
        vehicle                = vehicle,
        brokenEngineIni        = brokenEngineINI,
        baseTorqueCurve        = torqueCurve,
        uiTorqueCurveAvailable = uiTorqueCurveAvailable,
        turboData              = turboData,
        idleRPM                = idleRPM,
        maxRPM                 = maxRPM,
        RPMRange               = maxRPM - idleRPM,
        defaultShiftUpRPM      = defaultShiftUp,
        gearRatios             = table.clone(cPhys.gearRatios, true),
        finalDrive             = cPhys.finalRatio,
    }, self)
end

function M:getNormalizedRPM(rpm)
    rpm = rpm or self.vehicle.rpm
    return math.lerpInvSat(rpm, self.idleRPM, self.maxRPM)
end

function M:getAbsoluteRPM(normalizedRPM)
    return math.lerp(self.idleRPM, self.maxRPM, normalizedRPM)
end

-- Max theoretical torque at full throttle
function M:getMaxTQ(rpm, gear)
    if not self.baseTorqueCurve then
        return 0
    end

    local baseTorque = self.baseTorqueCurve:get(rpm)

    if self.uiTorqueCurveAvailable then
        return baseTorque
    end

    local totalBoost = 0.0

    for _, turbo in ipairs(self.turboData) do
        local baseLevel = math.min(1.0, (rpm / turbo.referenceRPM) ^ turbo.gamma)

        local boostMult = turbo.maxBoost

        if turbo.hasControllers then
            boostMult = 0.0
            for _, controller in ipairs(turbo.controllers) do
                local controllerValue = 0.0

                if controller.input == "RPMS" then
                    controllerValue = controller.LUT:get(rpm)
                elseif controller.input == "GEAR" then
                    controllerValue = controller.LUT:get(gear)
                elseif controller.input == "GAS" then
                    controllerValue = controller.LUT:get(1.0)
                elseif controller.input == "BRAKE" then
                    controllerValue = controller.LUT:get(0.0)
                elseif controller.input == "OVERSTEER_FACTOR" then
                    controllerValue = controller.LUT:get(0.0)
                else
                    -- // TODO later
                    controllerValue = 0.0
                end

                if controller.combinator == "ADD" then
                    boostMult = boostMult + controllerValue
                elseif controller.combinator == "MULT" then
                    boostMult = boostMult * controllerValue
                end

                if not math.isNaN(controller.upLimit) and controller.upLimit < boostMult then
                    boostMult = controller.upLimit
                end

                if not math.isNaN(controller.downLimit) and controller.downLimit > boostMult then
                    boostMult = controller.downLimit
                end
            end
        end

        boostMult = boostMult * baseLevel

        if turbo.wasteGate ~= 0 then
            boostMult = math.min(turbo.wasteGate, boostMult)
        end

        totalBoost = totalBoost + boostMult
    end

    return baseTorque * (1.0 + totalBoost)
end

-- Max theoretical power at full throttle
function M:getMaxHP(rpm, gear)
    return self:getMaxTQ(rpm, gear) * rpm / 5252.0
end

function M:getGearRatio(gear)
    gear = gear or self.vehicle.gear
    return self.gearRatios[gear + 1] or math.NaN
end

function M:getDrivetrainRatio(gear)
    gear = gear or self.vehicle.gear
    return self:getGearRatio(gear) * self.finalDrive
end

function M:getRPMInGear(gear, currentRPM)
    currentRPM = currentRPM or self.vehicle.rpm
    return self:getGearRatio(gear) / self:getGearRatio(self.vehicle.gear) * currentRPM
end

function M:calcShiftingTable(minNormRPM, maxNormRPM)
    local gearData = {}

    if self.vehicle.gearCount < 2 then
        return gearData
    end

    local minRPM          = self:getAbsoluteRPM(minNormRPM)
    local maxShiftRPM     = self:getAbsoluteRPM(maxNormRPM)
    local defaultFallback = self.defaultShiftUpRPM

    for gear = 1, self.vehicle.gearCount - 1, 1 do
        local bestUpshiftRPM = defaultFallback

        if self.vehicle.mgukDeliveryCount == 0 or self.uiTorqueCurveAvailable then
            local bestArea = 0
            -- local areaSkew = 1.0 --math.lerp(1.0, 1.25, (gear - 1) / (self.vehicle.gearCount - 2)) -- shifts the bias of the power integral higher as the gear number increases
            local nextOverCurrentRatio = self:getGearRatio(gear + 1) / self:getGearRatio(gear)
            local shiftPointRes = 400
            local areaRes = 50
            for i = 0, shiftPointRes, 1 do
                local upshiftRPM = self:getAbsoluteRPM(i / shiftPointRes)
                local nextGearRPM = upshiftRPM * nextOverCurrentRatio
                if nextGearRPM > minRPM then
                    local area = 0
                    for j = 0, areaRes, 1 do
                        local simRPM = math.lerp(nextGearRPM, upshiftRPM, j / areaRes)
                        area = area + self:getMaxHP(simRPM, gear) / areaRes -- * math.lerp(1.0, areaSkew, (j / areaRes))
                    end
                    if area > bestArea then
                        bestArea = area
                        bestUpshiftRPM = upshiftRPM
                    end
                end
            end
        end

        gearData[gear] = {
            upshiftRPM = math.min(bestUpshiftRPM, maxShiftRPM),
            gearStartRPM = (gear == 1) and self.idleRPM or (gearData[gear - 1].upshiftRPM * self:getGearRatio(gear) / self:getGearRatio(gear - 1))
        }
    end

    gearData[1].gearStartRPM = (self:getGearRatio(2) / self:getGearRatio(1)) * gearData[2].gearStartRPM
    gearData[self.vehicle.gearCount] = {
        upshiftRPM = 9999999,
        gearStartRPM = gearData[self.vehicle.gearCount - 1].upshiftRPM * self:getGearRatio(self.vehicle.gearCount) / self:getGearRatio(self.vehicle.gearCount - 1)
    }

    return gearData
end

return M