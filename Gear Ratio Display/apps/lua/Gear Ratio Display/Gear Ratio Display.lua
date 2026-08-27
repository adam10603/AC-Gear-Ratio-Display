local CarPerformanceData = require "CarPerformanceData2"

local savedCfg = ac.storage({
    metric             = true,
    showShiftingPoints = false
}, "GRD_")

local white                = rgbm(1.0, 1.0, 1.0, 1.0)
local graphPadding         = 48
local graphDivColor        = rgbm(1.0, 1.0, 1.0, 0.25)
local graphSubDivColor     = rgbm(1.0, 1.0, 1.0, 0.085)
local graphPathColor       = rgbm(59/255, 159/255, 255/255, 1)
local graphPathColor2      = rgbm(1.0, 1.0, 1.0, 1.0)
-- local graphYHighlightColor = rgbm(0.075, 0.75, 0.0, 0.3)
local graphYHighlightColor = rgbm(59/255, 159/255, 255/255, 0.375)
-- local graphYHighlightColor = rgbm(0.1, 1.0, 0.0, 0.2)
local graphYLimitColor     = rgbm(1.0, 0.0, 0.0, 0.5)
-- local graphYLimitColor     = rgbm(0.075, 0.75, 0.0, 1.0)
-- local graphPathColor     = rgbm(1.0, 0.0, 0.0, 1)

local powerBandThreshold = 0.98

local zeroVec          = vec2() -- Do not modify
local tmpVec1          = vec2()
local tmpVec2          = vec2()
local lineData         = {}
local lineData2        = {}
local prevGearSetHash  = 0
local powerBandStart = 0
local powerBandEnd   = 0
local canGetPowerBand  = true

local tooltips = {
    metric             = "Toggles between KPH and MPH.",
    showShiftingPoints = "Changes the graph to show the optimal shifting points (based on the engine's power curve).\n\nAlso highlights the ideal power band in blue. This is the RPM range where the engine outputs over 98% of its peak power.\n\nThis setting might not be available on certain cars!"
}

local function isNumberValid(x)
    return type(x) == "number" and not math.isnan(x) and not math.isinf(x)
end

---@param vehicle ac.StateCar
local function getReferenceWheelIndicies(vehicle)
    return (vehicle.tractionType == 1) and { 0, 1 } or { 2, 3 }
end

---@param vehicle ac.StateCar
local function getWheels(indicies, vehicle)
    return { vehicle.wheels[indicies[1]], vehicle.wheels[indicies[2]] }
end

---@param vehicle ac.StateCar
local function getPredictedSpeedForRPM(rpm, vehicle, drivetrainRatio)
    local referenceWheels = getWheels(getReferenceWheelIndicies(vehicle), vehicle)
    local wheelDiameter = (referenceWheels[1].tyreRadius + referenceWheels[2].tyreRadius)
    return (rpm * math.pi * wheelDiameter) / (60.0 * drivetrainRatio)
end

---@param vehicle ac.StateCar
local function getPredictedRPMForSpeed(speedKph, vehicle, drivetrainRatio)
    local referenceWheels = getWheels(getReferenceWheelIndicies(vehicle), vehicle)
    local wheelDiameter = (referenceWheels[1].tyreRadius + referenceWheels[2].tyreRadius)
    return speedKph * (60.0 * drivetrainRatio) / (math.pi * wheelDiameter)
end

-- Returns `true` if the gear set hash had to be updated
---@param vehicle ac.StateCar
---@param cPhys ac.StateCarPhysics
local function updateGearSetHash(vehicle, cPhys)

    if vehicle.gearCount < 1 or not cPhys.gearRatios or #cPhys.gearRatios == 0 then return false end

    local currentGearSetHash = 0

    for gear = 1, vehicle.gearCount, 1 do
        currentGearSetHash = currentGearSetHash + (cPhys.gearRatios[gear + 1] * gear * 16)
    end

    currentGearSetHash = currentGearSetHash + cPhys.finalRatio * 1024
    currentGearSetHash = currentGearSetHash + vehicle.rpmLimiter

    local ret = (currentGearSetHash ~= prevGearSetHash)

    prevGearSetHash = currentGearSetHash

    return ret
end

---@param vehicle ac.StateCar
---@param cPhys ac.StateCarPhysics
local function updateData(vehicle, cPhys)
    ac.log("updateData")

    table.clear(lineData)
    table.clear(lineData2)

    if vehicle.gearCount < 1 then return end

    local perfData = CarPerformanceData:new(vehicle, cPhys)

    local gearStartRPM   = 0
    local gearStartSpeed = 0 -- km/h

    for gear = 1, vehicle.gearCount, 1 do
        local currentDrivetrainRatio = perfData:getDrivetrainRatio(gear)
        if not isNumberValid(currentDrivetrainRatio) or currentDrivetrainRatio == 0 then break end
        local currentGearEndSpeed = getPredictedSpeedForRPM(perfData.maxRPM, vehicle, currentDrivetrainRatio) * 3.6
        table.insert(lineData, {
            { gearStartSpeed, gearStartRPM },
            { currentGearEndSpeed, perfData.maxRPM }
        })
        local curRatio  = perfData:getGearRatio(gear)
        local nextRatio = perfData:getGearRatio(gear + 1)
        gearStartSpeed  = currentGearEndSpeed
        gearStartRPM    = perfData.maxRPM * (nextRatio / curRatio)
    end

    if not perfData.brokenEngineIni and perfData.baseTorqueCurve and (vehicle.mgukDeliveryCount == 0 or perfData.uiTorqueCurveAvailable) then
        local shiftingTable = perfData:calcShiftingTable(0.1, 1.0)

        if #shiftingTable ~= vehicle.gearCount then
            return
        end

        gearStartRPM   = 0
        gearStartSpeed = 0 -- km/h

        for gear = 1, vehicle.gearCount, 1 do
            local currentGearEndRPM      = math.min(shiftingTable[gear].upshiftRPM, perfData.maxRPM)
            local currentDrivetrainRatio = perfData:getDrivetrainRatio(gear)
            if not isNumberValid(currentDrivetrainRatio) or currentDrivetrainRatio == 0 then break end
            local currentGearEndSpeed = getPredictedSpeedForRPM(currentGearEndRPM, vehicle, currentDrivetrainRatio) * 3.6
            table.insert(lineData2, {
                { gearStartSpeed, gearStartRPM },
                { currentGearEndSpeed, currentGearEndRPM }
            })
            local curRatio  = perfData:getGearRatio(gear)
            local nextRatio = perfData:getGearRatio(gear + 1)
            gearStartSpeed = currentGearEndSpeed
            gearStartRPM   = currentGearEndRPM * (nextRatio / curRatio)
        end
    end
end

---@param vehicle ac.StateCar
---@param cPhys ac.StateCarPhysics
---@param threshold number
local function updatePowerBand(vehicle, cPhys, threshold)

    if not canGetPowerBand then
        return
    end

    local perfData = CarPerformanceData:new(vehicle, cPhys)

    local maxPower = 0.0
    local powerTable = {}
    local targetGear = math.round(vehicle.gearCount * 0.75)
    local powerTableResolution = 300

    for i = 1, powerTableResolution, 1 do
        local rpm = perfData:getAbsoluteRPM(i / powerTableResolution)
        local power = perfData:getMaxHP(rpm, targetGear)
        powerTable[i] = power
        if power > maxPower then
            maxPower = power
        end
    end

    if maxPower == 0.0 then
        canGetPowerBand = false
        return
    end

    local powerBandMinimum = maxPower * threshold

    for i = 1, powerTableResolution, 1 do
        local rpm = perfData:getAbsoluteRPM(i / powerTableResolution)
        local power = powerTable[i]
        if power > powerBandMinimum then
            if powerBandStart == 0 then
                powerBandStart = rpm
            end
            powerBandEnd = rpm
        end
    end
end

local function addTooltipToLastItem(tooltipKey)
    if ui.itemHovered() and tooltipKey and tooltips[tooltipKey] then
        -- ui.pushStyleVarAlpha(0.5)
        ui.setTooltip(tooltips[tooltipKey])
        -- ui.popStyleVar()
    end
end

local function showCheckbox(cfgKey, name, inverted, disabled, indent)
    local val = not savedCfg[cfgKey]
    if not inverted then val = not val end
    ui.offsetCursorX(indent)
    if disabled then ui.pushDisabled() end
    if ui.checkbox(name, val) and not disabled then
        savedCfg[cfgKey] = not savedCfg[cfgKey]
    end
    if disabled then ui.popDisabled() end
    addTooltipToLastItem(cfgKey)
end

local function drawGraph(size, xTitle, yTitle, xMin, xMax, yMin, yMax, xDiv, yDiv, xMult, ySubDiv, lines, lines2, yHighlightMin, yHighlightMax, yLimitHighlight, yLimitHighlightText)
    ySubDiv = ySubDiv or 0

    ui.childWindow("GRD_Graph", size, false, ui.WindowFlags.NoBackground + ui.WindowFlags.NoScrollbar, function ()
        ui.pushFont(ui.Font.Small)

        local xOffset    = 20
        local topPadding = 15

        ui.drawLine(tmpVec1:set(graphPadding + xOffset, topPadding), tmpVec2:set(graphPadding + xOffset, size.y - graphPadding), white)
        ui.drawLine(tmpVec1:set(graphPadding + xOffset, size.y - graphPadding), tmpVec2:set(size.x - graphPadding + xOffset + 1, size.y - graphPadding), white)

        local xRange = xMax - xMin
        local yRange = yMax - yMin

        local xPPU = (size.x - 2 * graphPadding) / xRange -- Pixels per unit
        local yPPU = (size.y - graphPadding - topPadding) / yRange -- Pixels per unit

        ui.setCursorX(xOffset)
        ui.setCursorY(0)

        local graphWidth  = size.x - graphPadding * 2.0
        local graphHeight = size.y - graphPadding - topPadding

        if yHighlightMin ~= nil and yHighlightMax ~= nil then
            ui.drawRectFilled(
                tmpVec1:set(graphPadding + xOffset, math.round(topPadding + yPPU * (yMax - yHighlightMin))),
                tmpVec2:set(size.x - graphPadding + xOffset, math.round(topPadding + yPPU * (yMax - yHighlightMax))),
                graphYHighlightColor
            )

            ui.setCursorX(xOffset)
            ui.setCursorY(0)
        end

        for x = xMin, xMax, xDiv do
            ui.drawLine(
                tmpVec1:set(math.round(graphPadding + xPPU * (x - xMin) + xOffset) or 0, topPadding),
                tmpVec2:set(tmpVec1.x, size.y - graphPadding),
                graphDivColor
            )
            ui.textAligned(
                string.format("%.f", x),
                tmpVec1:set(
                    ((x - xMin) / xRange) * ((size.x - 2 * graphPadding + (graphWidth * 0.018)) / size.x) + ((graphPadding - (graphWidth * 0.0053333)) / size.x),
                    (size.y - graphPadding + 15) / size.y
                ),
                size
            )
            ui.setCursorX(xOffset)
            ui.setCursorY(0)
        end

        -- -- Prevents horizontal division lines from being drawn under the Y limit highlight line. Assumes the limit line is 3 thicc.
        -- local function shouldDrawLine(yPixelCoord)
        --     if yLimitHighlight ~= nil and yLimitHighlightPixelY > 0 then
        --         return math.abs(yLimitHighlightPixelY - yPixelCoord) > 1
        --     end
        -- end

        for y = yMin, yMax, yDiv do
            if ySubDiv >= 2 and y ~= yMin then
                for ySubdivIndex = 1, ySubDiv - 1, 1 do
                    local t = ySubdivIndex / ySubDiv
                    local lineYCoord = math.round(topPadding + yPPU * ((y - yDiv * t) - yMin))
                    ui.drawLine(
                        tmpVec1:set(graphPadding + xOffset, lineYCoord),
                        tmpVec2:set(size.x - graphPadding + xOffset, lineYCoord),
                        graphSubDivColor
                    )
                end
            end

            local lineYCoord = math.round(topPadding + yPPU * (y - yMin))

            ui.drawLine(
                tmpVec1:set(graphPadding + xOffset, lineYCoord),
                tmpVec2:set(size.x - graphPadding + xOffset, lineYCoord),
                graphDivColor
            )

            ui.textAligned(
                string.format("%.f", y),
                tmpVec1:set(
                    (graphPadding - 15 - xOffset) / size.x,
                    1.0 - (((y - yMin) / yRange) * ((size.y - graphPadding - topPadding + (graphHeight * 0.018)) / size.y) + ((graphPadding - (graphHeight * 0.0053333)) / size.y))
                ),
                size
            )
            ui.setCursorX(xOffset)
            ui.setCursorY(0)
        end

        if yLimitHighlight ~= nil and yLimitHighlight > 0 then
            local lineYCoord = math.round(topPadding + yPPU * ((yMax - yLimitHighlight) - yMin))
            ui.drawLine(
                tmpVec1:set(graphPadding + xOffset + 1, lineYCoord),
                tmpVec2:set(size.x - graphPadding + xOffset, lineYCoord),
                graphYLimitColor,
                3
            )
            ui.setCursorX(xOffset)
            ui.setCursorY(0)
        end

        for _, v in pairs(lines) do
            local lineX1 = (graphPadding + (v[1][1] - xMin) / xRange * graphWidth * xMult + xOffset) or 0
            local lineY1 = (topPadding + (1.0 - (v[1][2] - yMin) / yRange) * graphHeight) or 0
            local lineX2 = (graphPadding + (v[2][1] - xMin) / xRange * graphWidth * xMult + xOffset) or 0
            local lineY2 = (topPadding + (1.0 - (v[2][2] - yMin) / yRange) * graphHeight) or 0

            ui.drawLine(tmpVec1:set(lineX1, lineY1), tmpVec2:set(lineX2, lineY2), graphPathColor, 3)
        end

        if lines2 ~= nil and #lines2 > 1 then
            for i, v in pairs(lines2) do
                local lineX1 = (graphPadding + (v[1][1] - xMin) / xRange * graphWidth * xMult + xOffset) or 0
                local lineY1 = (topPadding + (1.0 - (v[1][2] - yMin) / yRange) * graphHeight) or 0
                local lineX2 = (graphPadding + (v[2][1] - xMin) / xRange * graphWidth * xMult + xOffset) or 0
                local lineY2 = (topPadding + (1.0 - (v[2][2] - yMin) / yRange) * graphHeight) or 0

                if i > 1 then
                    ui.pathLineTo(tmpVec1:set(lineX1, lineY1))
                    ui.pathSmoothStroke(graphPathColor, false, 3)
                    ui.drawCircleFilled(tmpVec1:set(lineX1, lineY1), 1.5, graphPathColor)
                end
                if i < #lines2 then
                    ui.pathLineTo(tmpVec1:set(lineX2, lineY2))
                end
            end

            for i, v in pairs(lines2) do
                -- local lineX1 = (graphPadding + (v[1][1] - xMin) / xRange * graphWidth * xMult + xOffset) or 0
                -- local lineY1 = (topPadding + (1.0 - (v[1][2] - yMin) / yRange) * graphHeight) or 0
                local lineX2 = (graphPadding + (v[2][1] - xMin) / xRange * graphWidth * xMult + xOffset) or 0
                local lineY2 = (topPadding + (1.0 - (v[2][2] - yMin) / yRange) * graphHeight) or 0

                -- if i > 1 then
                    -- ui.drawCircleFilled(tmpVec1:set(lineX1, lineY1), 5, graphPathColor2, 12)
                -- end
                if i < #lines2 then
                    ui.drawCircleFilled(tmpVec1:set(lineX2, lineY2), 5, graphPathColor2, 12)
                    
                    -- ui.setCursor(tmpVec1:set(lineX2 - 10, lineY2 - 25))
                    -- ui.textAligned(
                    --     string.format("%.1fk", math.round(v[2][2] * 0.01) * 0.1),
                    --     tmpVec1:set(0.0, 0.5),
                    --     tmpVec2:set(60.0, 20.0)
                    -- )
                end
            end
        end

        ui.offsetCursorY(size.y - graphPadding + 30)
        ui.textAligned(xTitle, tmpVec1:set(0.5, 0.0), tmpVec2:set(size.x, 0.0))
        ui.setCursor(zeroVec)

        ui.beginRotation()
        ui.offsetCursorY(size.y * 0.5)
        ui.setCursorX(graphPadding)
        ui.textAligned(yTitle, tmpVec1:set(0.5, 0.0), tmpVec2:set(size.x - graphPadding * 2, 0.0))
        ui.endRotation(180.0, tmpVec1:set(-size.x * 0.5 + graphPadding - 30, 0.0))

        -- if yLimitHighlight ~= nil and yLimitHighlight > 0 and yLimitHighlightText ~= nil then
        --     ui.setCursor(tmpVec1:set(graphPadding + xOffset + 5, math.round(topPadding + yPPU * ((yMax - yLimitHighlight) - yMin) - 20)))
        --     ui.pushStyleColor(ui.StyleColor.Text, graphYLimitColor)
        --     ui.textAligned(
        --         yLimitHighlightText,
        --         tmpVec1:set(0.0, 0.5),
        --         tmpVec2:set(120.0, 20.0)
        --     )
        --     ui.popStyleColor(1)
        -- end

        ui.popFont()

        return 0
    end)
end

local function getRpmDivision(maxRpm)
    if maxRpm <= 2000.0 then
        return 100.0
    elseif maxRpm <= 5000.0 then
        return 250.0
    elseif maxRpm <= 10000.0 then
        return 500.0
    else
        return 10.0 * getRpmDivision(maxRpm / 10.0)
    end
end

local function getSpeedDivision(maxSpeed)
    if maxSpeed <= 20.0 then
        return 2.5
    elseif maxSpeed <= 50.0 then
        return 5.0
    elseif maxSpeed <= 100.0 then
        return 10.0
    else
        return 10.0 * getSpeedDivision(maxSpeed / 10.0)
    end
end

function script.windowMain()
    local vehicle = ac.getCar(0)

    if not vehicle or vehicle.isAIControlled or not vehicle.physicsAvailable then return end

    ui.pushFont(ui.Font.Title)
    ui.textAligned("Gear Ratios", tmpVec1:set(0.5, 0.5), tmpVec2:set(ui.availableSpaceX(), 34))
    ui.popFont()

    local cPhys = ac.getCarPhysics(0)

    if not cPhys.gearRatios or #cPhys.gearRatios == 0 or not cPhys.finalRatio or cPhys.finalRatio == 0 then
        ui.setNextTextBold()
        ui.textColored("    Cannot read gear ratios!\n    This usually happens if a mod car has encrypted data files.", rgbm(1.0, 0.0, 0.0, 1.0))
        canGetPowerBand = false
        return
    end

    local gearSetHashUpdated = updateGearSetHash(vehicle, cPhys)

    if #lineData == 0 or gearSetHashUpdated then updateData(vehicle, cPhys) end
    if (powerBandStart == 0 and powerBandEnd == 0) or gearSetHashUpdated then updatePowerBand(vehicle, cPhys, powerBandThreshold) end

    local speedMult         = (savedCfg.metric and 1.0 or 0.62137119)
    local speedDiv          = getSpeedDivision(lineData[#lineData][2][1] * speedMult) --(savedCfg.metric and 50 or 25)
    local drawShifts        = (savedCfg.showShiftingPoints and #lineData2 > 1)
    local graphMaxSpeed     = math.ceil(lineData[#lineData][2][1] * speedMult / speedDiv) * speedDiv
    local graphMaxRpm       = math.ceil(lineData[#lineData][2][2] / 1000.0) * 1000.0
    local rpmDiv            = graphMaxRpm > 20000 and 2000 or 1000 -- simpler logic for main rpm divisions
    local rpmSubDivSimple   = rpmDiv / math.clamp(getRpmDivision(graphMaxRpm * 2.0), 125.0, 1000.0)
    local rpmSubDivAdvanced = rpmDiv / math.clamp(getRpmDivision(graphMaxRpm), 125.0, 1000.0)

    drawGraph(
        vec2(ui.availableSpace().x, ui.availableSpace().y - 40),
        savedCfg.metric and "Speed (KPH)" or "Speed (MPH)",
        "RPM",
        0,
        graphMaxSpeed,
        0,
        graphMaxRpm,
        speedDiv,
        rpmDiv,
        speedMult,
        drawShifts and rpmSubDivAdvanced or rpmSubDivSimple,
        drawShifts and lineData2 or lineData,
        drawShifts and lineData2 or nil,
        drawShifts and powerBandStart or nil,
        drawShifts and powerBandEnd or nil,
        lineData[#lineData][2][2] --drawShifts and lineData[#lineData][2][2] or nil
    )

    showCheckbox("metric", "Metric", false, false, 0)
    ui.sameLine()
    showCheckbox("showShiftingPoints", "Show shifting points", false, #lineData2 <= 1, 0)
end