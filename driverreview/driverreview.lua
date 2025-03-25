-- DriverReview: A WoW addon to rate driving skills in The War Within
-- Mimics an Uber-like review system for mount driving skills

local addonName, DR = ...
DR.version = "1.0.0"
DR.addonMessagePrefix = "DriverReview"
DR.playerName = UnitName("player")
DR.realmName = GetRealmName()
DR.fullPlayerName = DR.playerName .. "-" .. DR.realmName

-- Saved variables
DriverReviewDB = DriverReviewDB or {}
DriverReviewDB.ratings = DriverReviewDB.ratings or {}
DriverReviewDB.myRatings = DriverReviewDB.myRatings or {}

--------------------------------------------------------------------
-- Constants and Configuration
--------------------------------------------------------------------

-- Colors
local COLORS = {
    PRIMARY = {0.2, 0.6, 0.8, 1},
    SECONDARY = {0.1, 0.1, 0.1, 0.8},
    TEXT = {1, 1, 1, 1},
    STAR_ACTIVE = {1, 0.8, 0, 1},
    STAR_INACTIVE = {0.3, 0.3, 0.3, 1},
    UBER_BLUE = {0.07, 0.38, 0.47, 1},
    HORDE = {0.7, 0.2, 0.2, 1},     -- Red for Horde
    ALLIANCE = {0.2, 0.2, 0.7, 1}   -- Blue for Alliance
}

-- Sound constants
local SOUNDS = {
    RATING_SELECT = SOUNDKIT.IG_CHARACTER_INFO_TAB,
    NEW_REVIEW = SOUNDKIT.READY_CHECK
}

--------------------------------------------------------------------
-- Utilities and Helpers
--------------------------------------------------------------------

-- Frame pool system for UI elements
DR.framePools = {}

function DR:CreateFramePool(frameType, parent, template, resetterFunc)
    local pool = {
        frameType = frameType,
        parent = parent,
        template = template,
        resetterFunc = resetterFunc,
        activeFrames = {},
        inactiveFrames = {}
    }

    function pool:Acquire()
        local frame = table.remove(self.inactiveFrames)
        
        if not frame then
            frame = CreateFrame(self.frameType, nil, self.parent, self.template)
        end
        
        table.insert(self.activeFrames, frame)
        return frame
    end
    
    function pool:Release(frame)
        for i, activeFrame in ipairs(self.activeFrames) do
            if activeFrame == frame then
                table.remove(self.activeFrames, i)
                
                if self.resetterFunc then
                    self.resetterFunc(frame)
                end
                
                frame:Hide()
                table.insert(self.inactiveFrames, frame)
                return true
            end
        end
        return false
    end
    
    function pool:ReleaseAll()
        for i = #self.activeFrames, 1, -1 do
            self:Release(self.activeFrames[i])
        end
    end
    
    return pool
end

-- Enhanced debug system with throttling
local debugQueue = {}
local lastDebugFlush = 0
local FLUSH_INTERVAL = 0.5 -- seconds

function DR:Debug(message, category)
    if not DriverReviewDB.debug then return end
    
    category = category or "general"
    
    -- Check if debugging for this category is enabled
    if category ~= "general" and DriverReviewDB.debugCategories and not DriverReviewDB.debugCategories[category] then
        return
    end
    
    -- Add to queue
    table.insert(debugQueue, {
        message = message,
        category = category,
        timestamp = time()
    })
    
    -- If it's been long enough since last flush, flush now
    if time() - lastDebugFlush > FLUSH_INTERVAL then
        self:FlushDebugQueue()
    end
end

function DR:FlushDebugQueue()
    if #debugQueue == 0 then return end
    
    local categoryColor = {
        general = "00CCFF",
        driver = "FF9900",  -- Orange for driver selection
        portrait = "33FF33", -- Green for portrait loading
        rating = "FF3399",   -- Pink for rating
        comment = "FFFF00",  -- Yellow for comments
        dropdown = "FF0000"  -- Red for dropdown issues
    }
    
    for _, entry in ipairs(debugQueue) do
        local color = categoryColor[entry.category] or "00CCFF"
        local prefix = "|cFF" .. color .. "[DriverReview:" .. entry.category .. "]|r "
        print(prefix .. tostring(entry.message))
        
        -- Also log to debug frame if it exists
        if self.debugFrame and self.debugFrame:IsShown() then
            self:AddDebugMessage(prefix .. tostring(entry.message))
        end
    end
    
    wipe(debugQueue)
    lastDebugFlush = time()
end

-- Improved error handler
function DR:ErrorHandler(context, func)
    return function(...)
        local success, result = pcall(func, ...)
        if not success then
            self:Debug("ERROR in " .. context .. ": " .. tostring(result), "general")
            
            -- Try to get stack trace
            local stack = debugstack()
            if stack then
                self:Debug("STACK: " .. stack:sub(1, 500), "general")
            end
            
            -- Show notification to user
            self:ShowNotification("Error in " .. context .. ". Check debug log.", "error")
            return nil
        end
        return result
    end
end

-- Standard UI helper functions
function DR:CreateStandardFrame(parent, width, height, title)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(width, height)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 }
    })
    frame:SetBackdropColor(COLORS.SECONDARY[1], COLORS.SECONDARY[2], COLORS.SECONDARY[3], COLORS.SECONDARY[4])
    
    if title then
        local titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        titleText:SetPoint("TOP", 0, -10)
        titleText:SetText(title)
        frame.titleText = titleText
    end
    
    return frame
end

-- Create a simple button with text
function DR:CreateButton(parent, width, height, text, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, height)
    button:SetText(text)
    
    if onClick then
        button:SetScript("OnClick", onClick)
    end
    
    return button
end

-- Create a standard edit box
function DR:CreateEditBox(parent, width, height)
    local editBox = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    editBox:SetSize(width, height)
    editBox:SetAutoFocus(false)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    
    return editBox
end

-- Create stars for rating
function DR:CreateRatingStars(parent, size, spacing, onRatingChanged)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize((size + spacing) * 5, size)
    
    local stars = {}
    for i = 1, 5 do
        -- Create container for each star
        local starContainer = CreateFrame("Frame", nil, container)
        starContainer:SetSize(size, size)
        starContainer:SetPoint("LEFT", (i-1) * (size + spacing), 0)
        
        -- Create star icon
        local star = starContainer:CreateTexture(nil, "ARTWORK")
        star:SetSize(size, size)
        star:SetPoint("CENTER")
        
        -- Default to empty star
        star:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
        star:SetVertexColor(COLORS.STAR_INACTIVE[1], COLORS.STAR_INACTIVE[2], COLORS.STAR_INACTIVE[3], COLORS.STAR_INACTIVE[4])
        
        -- Number label
        local text = starContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("BOTTOM", 0, -5)
        text:SetText(tostring(i))
        
        -- Set up click handlers
        starContainer:SetScript("OnEnter", function()
            container:UpdateHighlight(i)
        end)
        
        starContainer:SetScript("OnLeave", function()
            container:UpdateDisplay()
        end)
        
        starContainer:SetScript("OnMouseDown", function()
            container:SetRating(i)
            PlaySound(SOUNDS.RATING_SELECT)
            
            if onRatingChanged then
                onRatingChanged(i)
            end
        end)
        
        -- Make the container interactive
        starContainer:EnableMouse(true)
        stars[i] = star
    end
    
    container.stars = stars
    container.currentRating = 0
    
    -- Methods
    function container:SetRating(value)
        self.currentRating = value
        self:UpdateDisplay()
    end
    
    function container:GetRating()
        return self.currentRating
    end
    
    function container:UpdateDisplay()
        local rating = self.currentRating or 0
        
        for i = 1, 5 do
            if i <= rating then
                self.stars[i]:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-Ready")
                self.stars[i]:SetVertexColor(COLORS.STAR_ACTIVE[1], COLORS.STAR_ACTIVE[2], COLORS.STAR_ACTIVE[3], COLORS.STAR_ACTIVE[4])
            else
                self.stars[i]:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
                self.stars[i]:SetVertexColor(COLORS.STAR_INACTIVE[1], COLORS.STAR_INACTIVE[2], COLORS.STAR_INACTIVE[3], COLORS.STAR_INACTIVE[4])
            end
        end
        
        if self.ratingText then
            if rating > 0 then
                self.ratingText:SetText(rating .. " star" .. (rating ~= 1 and "s" or ""))
                self.ratingText:SetTextColor(1, 0.82, 0, 1)
            else
                self.ratingText:SetText("")
            end
        end
    end
    
    function container:UpdateHighlight(index)
        for i = 1, 5 do
            if i <= index then
                self.stars[i]:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-Ready")
                self.stars[i]:SetVertexColor(COLORS.STAR_ACTIVE[1], COLORS.STAR_ACTIVE[2], COLORS.STAR_ACTIVE[3], COLORS.STAR_ACTIVE[4])
            else
                self.stars[i]:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
                self.stars[i]:SetVertexColor(COLORS.STAR_INACTIVE[1], COLORS.STAR_INACTIVE[2], COLORS.STAR_INACTIVE[3], COLORS.STAR_INACTIVE[4])
            end
        end
        
        if self.ratingText then
            self.ratingText:SetText(index .. " star" .. (index ~= 1 and "s" or ""))
            self.ratingText:SetTextColor(1, 0.82, 0, 1)
        end
    end
    
    -- Add optional rating text
    function container:SetRatingText(fontString)
        self.ratingText = fontString
    end
    
    return container
end

-- Data access layer
DR.DataStore = {}

function DR.DataStore:GetPlayerRating(playerName)
    if not DriverReviewDB.ratings[playerName] then
        return nil, 0
    end
    
    local ratings = DriverReviewDB.ratings[playerName]
    local totalRating = 0
    
    for _, rating in ipairs(ratings) do
        totalRating = totalRating + (rating.rating or 0)
    end
    
    local averageRating = #ratings > 0 and (totalRating / #ratings) or 0
    return ratings, averageRating
end

function DR.DataStore:AddMyRating(driver, rating)
    if not DriverReviewDB.myRatings then
        DriverReviewDB.myRatings = {}
    end
    
    -- Check if player already has a review - if so, remove all existing reviews
    if DriverReviewDB.myRatings[driver] then
        DriverReviewDB.myRatings[driver] = {}
    else
        DriverReviewDB.myRatings[driver] = {}
    end
    
    -- Add the new review
    table.insert(DriverReviewDB.myRatings[driver], rating)
    return true
end

function DR.DataStore:DeleteMyRating(ratingToDelete)
    if not ratingToDelete then return false end
    
    -- Find the rating in the database
    for driver, ratings in pairs(DriverReviewDB.myRatings or {}) do
        for i, rating in ipairs(ratings) do
            -- Check if this is the rating we want to delete
            if rating.timestamp == ratingToDelete.timestamp and 
               rating.driver == ratingToDelete.driver then
                -- Remove this rating
                table.remove(ratings, i)
                DR:Debug("Deleted rating for " .. (rating.driverName or driver), "rating")
                
                -- If no more ratings for this driver, remove the driver entry
                if #ratings == 0 then
                    DriverReviewDB.myRatings[driver] = nil
                end
                
                return true
            end
        end
    end
    
    return false
end

function DR.DataStore:DeleteReview(reviewToDelete)
    if not reviewToDelete or not DriverReviewDB.ratings[DR.fullPlayerName] then
        return false
    end
    
    -- Look through all reviews for the player
    for i, review in ipairs(DriverReviewDB.ratings[DR.fullPlayerName]) do
        -- Check if this is the review we want to delete (match by timestamp and reviewer)
        if review.timestamp == reviewToDelete.timestamp and 
           review.reviewer == reviewToDelete.reviewer then
            -- Remove this review
            table.remove(DriverReviewDB.ratings[DR.fullPlayerName], i)
            
            return true
        end
    end
    
    return false
end

function DR.DataStore:GetReviewsForPlayer(playerName)
    return DriverReviewDB.ratings[playerName] or {}
end

function DR.DataStore:GetAllMyRatings()
    local allRatings = {}
    for driver, ratings in pairs(DriverReviewDB.myRatings or {}) do
        for _, rating in ipairs(ratings) do
            -- Make sure we have a valid driver name
            if not rating.driverName or rating.driverName == "" then
                local extractedName = driver:match("([^-]+)")
                if extractedName then
                    rating.driverName = extractedName
                else
                    rating.driverName = driver
                end
            end
            table.insert(allRatings, rating)
        end
    end
    
    -- Sort by timestamp (newest first)
    table.sort(allRatings, function(a, b)
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)
    
    return allRatings
end

function DR.DataStore:StorePlayerData(unitOrName, fullName)
    if not DriverReviewDB.playerData then
        DriverReviewDB.playerData = {}
    end
    
    local playerData = {}
    
    if type(unitOrName) == "string" and not UnitExists(unitOrName) then
        -- This is just a name, not a unit
        -- We don't have unit data, but let's store the name
        local name, realm = unitOrName:match("([^-]+)-?(.*)")
        if not realm or realm == "" then
            realm = GetRealmName()
        end
        
        playerData = {
            name = name,
            realm = realm,
            lastUpdated = time()
        }
    else
        -- This is a unit ID
        local unit = unitOrName
        local _, class = UnitClass(unit)
        local classFileName = select(2, UnitClass(unit))
        local faction = UnitFactionGroup(unit)
        local race = UnitRace(unit)
        local level = UnitLevel(unit)
        
        playerData = {
            class = class,
            classFileName = classFileName,
            faction = faction,
            race = race,
            level = level,
            lastUpdated = time()
        }
    end
    
    DriverReviewDB.playerData[fullName] = playerData
    return playerData
end

function DR.DataStore:GetPlayerData(fullName)
    if not DriverReviewDB.playerData then
        return nil
    end
    
    return DriverReviewDB.playerData[fullName]
end

function DR.DataStore:StoreReviewerInfo(reviewer)
    if not DriverReviewDB.reviewerHistory then
        DriverReviewDB.reviewerHistory = {}
    end
    
    DriverReviewDB.reviewerHistory[reviewer] = time()
end

function DR.DataStore:GetRatedPlayers()
    local players = {}
    local seen = {}
    
    -- Collect from players we've rated
    for driver, ratings in pairs(DriverReviewDB.myRatings or {}) do
        if not seen[driver] then
            local name, realm = driver:match("([^-]+)-?(.*)")
            if not realm or realm == "" then
                realm = GetRealmName()
            end
            
            table.insert(players, {
                name = name,
                fullName = driver,
                unit = nil,
                source = "rated_by_me",
                realm = realm
            })
            
            seen[driver] = true
        end
    end
    
    -- Collect from players who've rated us
    for reviewer, _ in pairs(DriverReviewDB.reviewerHistory or {}) do
        if not seen[reviewer] then
            local name, realm = reviewer:match("([^-]+)-?(.*)")
            if not realm or realm == "" then
                realm = GetRealmName()
            end
            
            table.insert(players, {
                name = name,
                fullName = reviewer,
                unit = nil,
                source = "rated_me",
                realm = realm
            })
            
            seen[reviewer] = true
        end
    end
    
    return players
end

-- Safe message serialization/deserialization
function DR:SerializeMessage(message)
    local safe = {}
    
    for k, v in pairs(message) do
        if type(v) == "table" then
            safe[k] = self:SerializeTable(v)
        elseif type(v) == "string" then
            safe[k] = string.format("%q", v)
        elseif type(v) == "number" or type(v) == "boolean" then
            safe[k] = tostring(v)
        else
            safe[k] = string.format("%q", tostring(v))
        end
    end
    
    local result = "{"
    local first = true
    
    for k, v in pairs(safe) do
        if not first then
            result = result .. ","
        else
            first = false
        end
        
        if type(k) == "string" then
            result = result .. string.format("[%q]", k) .. "=" .. v
        else
            result = result .. "[" .. tostring(k) .. "]=" .. v
        end
    end
    
    result = result .. "}"
    return result
end

function DR:SerializeTable(tbl)
    if type(tbl) ~= "table" then
        if type(tbl) == "string" then
            return string.format("%q", tbl)
        elseif type(tbl) == "nil" then
            return "nil"
        else
            return tostring(tbl)
        end
    end
    
    local result = "{"
    
    for k, v in pairs(tbl) do
        local key
        if type(k) == "string" then
            key = string.format("[%q]", k)
        else
            key = "[" .. tostring(k) .. "]"
        end
        
        local value
        if type(v) == "table" then
            value = self:SerializeTable(v)
        elseif type(v) == "string" then
            value = string.format("%q", v)
        elseif type(v) == "nil" then
            value = "nil"
        else
            value = tostring(v)
        end
        
        result = result .. key .. "=" .. value .. ","
    end
    
    -- Remove the trailing comma and close the table
    if result:sub(-1) == "," then
        result = result:sub(1, -2)
    end
    
    result = result .. "}"
    return result
end

function DR:DeserializeMessage(message)
    -- Use a safer approach than loadstring for parsing
    local success, data = pcall(function()
        local func, err = loadstring("return " .. message)
        if not func then 
            DR:Debug("Error parsing message: " .. tostring(err), "general")
            return nil
        end
        
        -- Create a sandboxed environment
        local env = {}
        setfenv(func, env)
        return func()
    end)
    
    if not success or not data then
        DR:Debug("Error processing addon message: " .. tostring(data), "general")
        return nil
    end
    
    return data
end

-- Show a notification popup with type support (normal, success, error)
function DR:ShowNotification(message, notificationType)
    notificationType = notificationType or "normal"
    
    if not self.notificationFrame then
        self.notificationFrame = self:CreateStandardFrame(UIParent, 300, 60)
        self.notificationFrame:SetPoint("TOP", 0, -100)
        
        self.notificationText = self.notificationFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        self.notificationText:SetPoint("CENTER")
        
        -- Add an icon for visual feedback
        self.notificationIcon = self.notificationFrame:CreateTexture(nil, "OVERLAY")
        self.notificationIcon:SetSize(24, 24)
        self.notificationIcon:SetPoint("LEFT", 20, 0)
        
        self.notificationFrame:SetScript("OnUpdate", function(self, elapsed)
            self.timeLeft = (self.timeLeft or 3) - elapsed
            if self.timeLeft <= 0 then
                self:Hide()
            end
        end)
    end
    
    -- Set appropriate colors and icons based on notification type
    if notificationType == "error" then
        self.notificationFrame:SetBackdropColor(0.8, 0.1, 0.1, 0.9)  -- Red for errors
        self.notificationText:SetTextColor(1, 1, 1)
        self.notificationIcon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
    elseif notificationType == "success" then
        self.notificationFrame:SetBackdropColor(0.1, 0.8, 0.1, 0.9)  -- Green for success
        self.notificationText:SetTextColor(1, 1, 1)
        self.notificationIcon:SetTexture("Interface\\BUTTONS\\UI-CheckBox-Check")
    else
        -- Default Uber blue for normal notifications
        self.notificationFrame:SetBackdropColor(COLORS.UBER_BLUE[1], COLORS.UBER_BLUE[2], COLORS.UBER_BLUE[3], COLORS.UBER_BLUE[4])
        self.notificationText:SetTextColor(1, 1, 1)
        self.notificationIcon:SetTexture("Interface\\COMMON\\voicechat-speaker")
    end
    
    -- Set the message text with appropriate padding for the icon
    self.notificationText:SetText(message)
    self.notificationFrame.timeLeft = 3
    self.notificationFrame:Show()
    
    -- Log the notification
    self:Debug("Notification [" .. notificationType .. "]: " .. message, "general")
end

--------------------------------------------------------------------
-- Group and Player Management
--------------------------------------------------------------------

-- Get current group members with caching
local groupCache = {}
local lastGroupUpdate = 0

function DR:GetGroupMembers()
    -- Check if cache is recent
    if time() - lastGroupUpdate < 2 then
        return groupCache
    end
    
    -- Update cache
    local members = {}
    local numMembers = GetNumGroupMembers()
    
    -- Always add player
    table.insert(members, {
        name = UnitName("player"),
        fullName = DR.fullPlayerName,
        unit = "player",
        realm = GetRealmName()
    })
    
    if numMembers > 0 then
        local prefix = IsInRaid() and "raid" or "party"
        
        for i = 1, numMembers do
            local unit = prefix .. i
            -- Skip if this is the player (already added) in party
            if IsInRaid() or UnitName(unit) ~= DR.playerName then
                local name = UnitName(unit)
                if name then
                    local _, realm = UnitFullName(unit)
                    realm = realm or GetRealmName()
                    local fullName = name .. "-" .. realm
                    table.insert(members, {
                        name = name,
                        fullName = fullName,
                        unit = unit,
                        realm = realm
                    })
                end
            end
        end
    end
    
    groupCache = members
    lastGroupUpdate = time()
    return members
end

--------------------------------------------------------------------
-- UI Components
--------------------------------------------------------------------

-- Create the portrait frame 
function DR:CreatePortraitFrame(parent)
    -- Create portrait frame
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(84, 84)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        tile = true,
        tileSize = 32,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    frame:SetBackdropColor(0, 0, 0, 0.7)
    
    -- Portrait texture itself
    local portraitTexture = frame:CreateTexture(nil, "ARTWORK")
    portraitTexture:SetSize(64, 64)
    portraitTexture:SetPoint("CENTER", frame, "CENTER", 0, 0)
    portraitTexture:SetTexture("Interface\\CharacterFrame\\TempPortrait")
    frame.portraitTexture = portraitTexture
    
    -- Create Alliance faction icon
    local allianceBorder = frame:CreateTexture(nil, "OVERLAY")
    allianceBorder:SetTexture("Interface\\BattlefieldFrame\\UI-Battlefield-Icon")
    allianceBorder:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    allianceBorder:SetSize(24, 24)
    allianceBorder:Hide()
    frame.allianceBorder = allianceBorder
    
    -- Create Horde faction icon
    local hordeBorder = frame:CreateTexture(nil, "OVERLAY") 
    hordeBorder:SetTexture("Interface\\BattlefieldFrame\\UI-Battlefield-Icon")
    hordeBorder:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    hordeBorder:SetSize(24, 24)
    hordeBorder:Hide()
    frame.hordeBorder = hordeBorder
    
    -- Methods
    function frame:UpdatePortrait(unit)
        if not unit or not UnitExists(unit) then
            self.portraitTexture:SetTexture("Interface\\CharacterFrame\\TempPortrait")
            self.allianceBorder:Hide()
            self.hordeBorder:Hide()
            return false
        end
        
        -- Try to set portrait
        local success = false
        
        -- Method 1: SetPortraitTexture
        pcall(function()
            SetPortraitTexture(self.portraitTexture, unit)
            success = true
        end)
        
        -- Method 2: Use class icon if player
        if not success and UnitIsPlayer(unit) then
            local _, class = UnitClass(unit)
            if class and CLASS_ICON_TCOORDS[class] then
                local coords = CLASS_ICON_TCOORDS[class]
                self.portraitTexture:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
                self.portraitTexture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                success = true
            end
        end
        
        -- Method 3: Fallback
        if not success then
            if UnitIsPlayer(unit) then
                self.portraitTexture:SetTexture("Interface\\CharacterFrame\\TempPortrait")
            else
                self.portraitTexture:SetTexture("Interface\\TARGETINGFRAME\\UI-TargetingFrame-Monster")
            end
        end
        
        -- Set faction indicator
        local faction = UnitFactionGroup(unit)
        self.allianceBorder:Hide()
        self.hordeBorder:Hide()
        
        if faction == "Alliance" then
            self.allianceBorder:Show()
            self.allianceBorder:SetVertexColor(COLORS.ALLIANCE[1], COLORS.ALLIANCE[2], COLORS.ALLIANCE[3], COLORS.ALLIANCE[4])
            self.allianceBorder:SetTexCoord(0.5, 1, 0, 0.5)
        elseif faction == "Horde" then
            self.hordeBorder:Show()
            self.hordeBorder:SetVertexColor(COLORS.HORDE[1], COLORS.HORDE[2], COLORS.HORDE[3], COLORS.HORDE[4])
            self.hordeBorder:SetTexCoord(0, 0.5, 0, 0.5)
        end
        
        return true
    end
    
    function frame:UpdateByName(name, realm)
        realm = realm or GetRealmName()
        local fullName = name .. "-" .. realm
        
        -- Set a generic portrait
        self.portraitTexture:SetTexture("Interface\\CharacterFrame\\TempPortrait")
        
        -- Try to set faction from cached data
        self.allianceBorder:Hide()
        self.hordeBorder:Hide()
        
        local playerData = DR.DataStore:GetPlayerData(fullName)
        if playerData and playerData.faction then
            if playerData.faction == "Alliance" then
                self.allianceBorder:Show()
                self.allianceBorder:SetVertexColor(COLORS.ALLIANCE[1], COLORS.ALLIANCE[2], COLORS.ALLIANCE[3], COLORS.ALLIANCE[4])
                self.allianceBorder:SetTexCoord(0.5, 1, 0, 0.5)
            elseif playerData.faction == "Horde" then
                self.hordeBorder:Show()
                self.hordeBorder:SetVertexColor(COLORS.HORDE[1], COLORS.HORDE[2], COLORS.HORDE[3], COLORS.HORDE[4])
                self.hordeBorder:SetTexCoord(0, 0.5, 0, 0.5)
            end
            
            -- If we have class data, try to use it
            if playerData.classFileName and CLASS_ICON_TCOORDS[playerData.classFileName] then
                local coords = CLASS_ICON_TCOORDS[playerData.classFileName]
                self.portraitTexture:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
                self.portraitTexture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
            end
        end
        
        return true
    end
    
    return frame
end

-- Create the search results frame
function DR:CreateSearchResultsFrame(parent)
    -- Create a container for search results
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(260, 90)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    
    -- Create a scrollframe for search results
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetSize(240, 80)
    scrollFrame:SetPoint("TOPLEFT", 5, -5)
    
    local scrollChild = CreateFrame("Frame")
    scrollFrame:SetScrollChild(scrollChild)
    scrollChild:SetSize(240, 100)  -- Will adjust height based on content
    
    frame.scrollFrame = scrollFrame
    frame.scrollChild = scrollChild
    
    -- Create a "no results" text that's hidden by default
    local noResultsText = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    noResultsText:SetPoint("CENTER")
    noResultsText:SetText("No players found")
    noResultsText:Hide()
    frame.noResultsText = noResultsText
    
    -- Create button pool
    frame.buttonPool = DR:CreateFramePool("Button", scrollChild, nil, function(button)
        button:ClearAllPoints()
        button.text:SetText("")
        button.resultData = nil
    end)
    
    -- Methods
    function frame:DisplayResults(results, onSelect)
        -- Clear previous results
        self.buttonPool:ReleaseAll()
        
        -- Reset scroll child height
        self.scrollChild:SetHeight(10)
        
        -- Hide no results text by default
        self.noResultsText:Hide()
        
        if #results == 0 then
            self.noResultsText:Show()
            return
        end
        
        -- Create buttons for results
        local yOffset = 5
        for i, result in ipairs(results) do
            local button = self.buttonPool:Acquire()
            button:SetSize(230, 25)
            
            -- Position the button
            button:SetPoint("TOPLEFT", 5, -yOffset)
            button:Show()
            
            -- Create text if needed
            if not button.text then
                button.text = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                button.text:SetPoint("LEFT", 5, 0)
                button.text:SetJustifyH("LEFT")
                
                -- Create highlight if needed
                local highlight = button:CreateTexture(nil, "HIGHLIGHT")
                highlight:SetAllPoints()
                highlight:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
                highlight:SetBlendMode("ADD")
            end
            
            -- Set realm info if it's different from player's realm
            local displayName = result.name
            if result.realm and result.realm ~= GetRealmName() then
                displayName = displayName .. " (" .. result.realm .. ")"
            end
            
            button.text:SetText(displayName)
            button.resultData = result
            
            -- Set click handler
            button:SetScript("OnClick", function(self)
                if onSelect then
                    onSelect(self.resultData)
                end
            end)
            
            -- Adjust offset for next button
            yOffset = yOffset + 25
        end
        
        -- Adjust scroll child height
        self.scrollChild:SetHeight(math.max(90, yOffset))
    end
    
    -- Initially hide the results frame
    frame:Hide()
    
    return frame
end

--------------------------------------------------------------------
-- Main Tab UI
--------------------------------------------------------------------

-- Create the main UI frame with tabs
function DR:CreateMainFrame()
    -- Main frame
    local frame = self:CreateStandardFrame(UIParent, 320, 450)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    self.frame = frame
    
    -- Title bar
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetSize(320, 40)
    titleBar:SetPoint("TOPLEFT")
    titleBar:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        tile = true,
        tileSize = 32
    })
    titleBar:SetBackdropColor(COLORS.UBER_BLUE[1], COLORS.UBER_BLUE[2], COLORS.UBER_BLUE[3], COLORS.UBER_BLUE[4])
    
    -- Title text
    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("CENTER", titleBar, "CENTER")
    titleText:SetText("WoW Driver")
    titleText:SetTextColor(1, 1, 1, 1)
    
    -- Close button
    local closeButton = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", 0, 0)
    closeButton:SetScript("OnClick", function() frame:Hide() end)
    
    -- Tab creation
    self:CreateTabs()
    
    -- Content frame
    self.contentFrame = CreateFrame("Frame", nil, frame)
    self.contentFrame:SetSize(300, 370)
    self.contentFrame:SetPoint("TOPLEFT", 10, -50)
    
    -- Create tab content
    self:CreateRateDriverTab()
    self:CreateMyRatingsTab()
    self:CreateMyReviewsTab()
    
    -- Show the first tab by default
    self:SwitchTab(1)
    
    return frame
end

-- Create tab buttons
function DR:CreateTabs()
    self.tabs = {}
    local tabNames = {"Rate Driver", "My Ratings", "My Reviews"}
    
    for i, name in ipairs(tabNames) do
        local tab = CreateFrame("Button", nil, self.frame, "BackdropTemplate")
        tab:SetSize(100, 25)
        tab:SetPoint("TOPLEFT", (i-1)*101, -40)
        tab:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 12,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        tab:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
        
        local text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("CENTER")
        text:SetText(name)
        
        tab:SetScript("OnClick", function()
            self:SwitchTab(i)
        end)
        
        self.tabs[i] = {
            button = tab,
            text = text
        }
    end
end

-- Switch between tabs
function DR:SwitchTab(tabIndex)
    for i, tab in ipairs(self.tabs) do
        if i == tabIndex then
            tab.button:SetBackdropColor(0.2, 0.2, 0.2, 1)
            tab.text:SetTextColor(1, 1, 1, 1)
        else
            tab.button:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            tab.text:SetTextColor(0.7, 0.7, 0.7, 1)
        end
    end
    
    -- Hide all tab content
    if self.rateDriverFrame then self.rateDriverFrame:Hide() end
    if self.myRatingsFrame then self.myRatingsFrame:Hide() end
    if self.myReviewsFrame then self.myReviewsFrame:Hide() end
    
    -- Show selected tab content
    if tabIndex == 1 and self.rateDriverFrame then 
        self.rateDriverFrame:Show()
    elseif tabIndex == 2 and self.myRatingsFrame then 
        self.myRatingsFrame:Show()
        self:UpdateMyRatings()
    elseif tabIndex == 3 and self.myReviewsFrame then 
        self.myReviewsFrame:Show()
        self:UpdateMyReviews()
    end
    
    self.currentTab = tabIndex
end

-- Create the Rate Driver tab
function DR:CreateRateDriverTab()
    self.rateDriverFrame = CreateFrame("Frame", nil, self.contentFrame)
    self.rateDriverFrame:SetSize(300, 370)
    self.rateDriverFrame:SetPoint("TOPLEFT")
    
    -- Create search label
    local searchLabel = self.rateDriverFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    searchLabel:SetPoint("TOPLEFT", 10, -10)
    searchLabel:SetText("Search Driver:")
    
    -- Create search box
    self.searchEditBox = self:CreateEditBox(self.rateDriverFrame, 200, 20)
    self.searchEditBox:SetPoint("TOPLEFT", 10, -30)
    self.searchEditBox:SetScript("OnEnterPressed", function(self) 
        DR:SearchDriver(self:GetText()) 
    end)
    
    -- Create search button
    self.searchButton = self:CreateButton(self.rateDriverFrame, 70, 22, "Search", function()
        DR:SearchDriver(DR.searchEditBox:GetText())
    end)
    self.searchButton:SetPoint("LEFT", self.searchEditBox, "RIGHT", 5, 0)
    
    -- Create search results frame
    self.searchResultsFrame = self:CreateSearchResultsFrame(self.rateDriverFrame)
    self.searchResultsFrame:SetPoint("TOPLEFT", 10, -55)
    
    -- Create portrait frame
    self.portraitFrame = self:CreatePortraitFrame(self.rateDriverFrame)
    self.portraitFrame:SetPoint("TOPLEFT", 10, -80)
    
    -- Create driver info text
    self.driverNameText = self.rateDriverFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.driverNameText:SetPoint("TOPLEFT", self.portraitFrame, "TOPRIGHT", 15, 0)
    self.driverNameText:SetPoint("RIGHT", self.rateDriverFrame, "RIGHT", -15, 0)
    self.driverNameText:SetJustifyH("LEFT")
    self.driverNameText:SetText("Select a driver")
    
    self.driverInfoText = self.rateDriverFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.driverInfoText:SetPoint("TOPLEFT", self.driverNameText, "BOTTOMLEFT", 0, -5)
    self.driverInfoText:SetPoint("RIGHT", self.rateDriverFrame, "RIGHT", -15, 0)
    self.driverInfoText:SetHeight(60)
    self.driverInfoText:SetJustifyH("LEFT")
    self.driverInfoText:SetJustifyV("TOP")
    self.driverInfoText:SetText("to review")
    
    -- Rating label
    local ratingLabel = self.rateDriverFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ratingLabel:SetPoint("TOPLEFT", 10, -210)
    ratingLabel:SetText("Rating")
    
    -- Rating stars
    local ratingText = self.rateDriverFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ratingText:SetPoint("LEFT", 220, -235)
    ratingText:SetText("")
    
    self.ratingStars = self:CreateRatingStars(self.rateDriverFrame, 32, 10, function(rating)
        self.currentRating = rating
    end)
    self.ratingStars:SetPoint("TOPLEFT", 10, -235)
    self.ratingStars:SetRatingText(ratingText)
    
    -- Review comment
    local commentLabel = self.rateDriverFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    commentLabel:SetPoint("TOPLEFT", 10, -290)
    commentLabel:SetText("Comment:")
    
    self.commentEditBox = self:CreateEditBox(self.rateDriverFrame, 270, 20)
    self.commentEditBox:SetPoint("TOPLEFT", 10, -310)
    
    -- Submit button
    self.submitButton = self:CreateButton(self.rateDriverFrame, 100, 25, "Submit Review", function()
        DR:SubmitReview()
    end)
    self.submitButton:SetPoint("BOTTOM", 0, 10)
end

-- Create the My Ratings tab
function DR:CreateMyRatingsTab()
    self.myRatingsFrame = CreateFrame("Frame", nil, self.contentFrame)
    self.myRatingsFrame:SetSize(300, 370)
    self.myRatingsFrame:SetPoint("TOPLEFT")
    
    -- Title
    local titleText = self.myRatingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", 10, -10)
    titleText:SetText("Ratings You've Given")
    
    -- Create a scrollframe for the ratings
    self.myRatingsScrollFrame = CreateFrame("ScrollFrame", nil, self.myRatingsFrame, "UIPanelScrollFrameTemplate")
    self.myRatingsScrollFrame:SetSize(280, 330)
    self.myRatingsScrollFrame:SetPoint("TOPLEFT", 10, -40)
    
    self.myRatingsScrollChild = CreateFrame("Frame")
    self.myRatingsScrollFrame:SetScrollChild(self.myRatingsScrollChild)
    self.myRatingsScrollChild:SetSize(280, 500)
    
    -- Create frame pool for rating cards
    self.ratingCardPool = self:CreateFramePool("Frame", self.myRatingsScrollChild, "BackdropTemplate", function(frame)
        frame:ClearAllPoints()
        frame:Hide()
    end)
end

-- Create the My Reviews tab
function DR:CreateMyReviewsTab()
    self.myReviewsFrame = CreateFrame("Frame", nil, self.contentFrame)
    self.myReviewsFrame:SetSize(300, 370)
    self.myReviewsFrame:SetPoint("TOPLEFT")
    
    -- Title
    local titleText = self.myReviewsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", 10, -10)
    titleText:SetText("Reviews You've Received")
    
    -- Overall rating
    self.overallRatingText = self.myReviewsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.overallRatingText:SetPoint("TOPLEFT", 10, -40)
    self.overallRatingText:SetText("Overall Rating: N/A")
    
    -- Create overall stars container
    self.overallStarsContainer = CreateFrame("Frame", nil, self.myReviewsFrame)
    self.overallStarsContainer:SetSize(120, 24)
    self.overallStarsContainer:SetPoint("TOPLEFT", self.overallRatingText, "BOTTOMLEFT", 0, -5)
    
    -- Create overall stars
    self.overallStars = {}
    for i = 1, 5 do
        local star = self.overallStarsContainer:CreateTexture(nil, "ARTWORK")
        star:SetSize(20, 20)
        star:SetPoint("LEFT", (i-1)*22, 0)
        self.overallStars[i] = star
    end
    
    -- Create a scrollframe for the reviews
    self.myReviewsScrollFrame = CreateFrame("ScrollFrame", nil, self.myReviewsFrame, "UIPanelScrollFrameTemplate")
    self.myReviewsScrollFrame:SetSize(280, 300)
    self.myReviewsScrollFrame:SetPoint("TOPLEFT", 10, -70)
    
    self.myReviewsScrollChild = CreateFrame("Frame")
    self.myReviewsScrollFrame:SetScrollChild(self.myReviewsScrollChild)
    self.myReviewsScrollChild:SetSize(280, 500)
    
    -- Help text for deleting reviews
    local helpText = self.myReviewsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    helpText:SetPoint("BOTTOMLEFT", 10, 5)
    helpText:SetText("Click the 'X' to remove unwanted reviews.")
    helpText:SetTextColor(0.7, 0.7, 0.7, 1)
    
    -- Create frame pool for review cards
    self.reviewCardPool = self:CreateFramePool("Frame", self.myReviewsScrollChild, "BackdropTemplate", function(frame)
        frame:ClearAllPoints()
        frame:Hide()
    end)
end

--------------------------------------------------------------------
-- Core Functionality
--------------------------------------------------------------------

-- Optimized search function
function DR:SearchDriver(searchText)
    if not searchText or searchText == "" then
        self:Debug("Empty search text", "driver")
        self:ShowNotification("Please enter a player name to search", "error")
        return
    end
    
    searchText = searchText:lower():trim()
    self:Debug("Searching for driver: " .. searchText, "driver")
    
    -- Prepare to collect results
    local results = {}
    local seen = {}
    
    -- Check current group members first (most efficient)
    local groupMembers = self:GetGroupMembers()
    for _, member in ipairs(groupMembers) do
        if member.name:lower():find(searchText, 1, true) then
            table.insert(results, member)
            seen[member.fullName] = true
        end
    end
    
    -- Only check history if not enough results from group
    if #results < 5 then
        local ratedPlayers = self.DataStore:GetRatedPlayers()
        for _, player in ipairs(ratedPlayers) do
            if not seen[player.fullName] and player.name:lower():find(searchText, 1, true) then
                table.insert(results, player)
                seen[player.fullName] = true
                
                -- Limit results
                if #results >= 10 then
                    break
                end
            end
        end
    end
    
    -- If no results found, create an entry for the search text
    if #results == 0 then
        local name, realm = searchText:match("([^-]+)-?(.*)")
        name = name:gsub("^%l", string.upper) -- Capitalize first letter
        
        if not realm or realm == "" then
            realm = GetRealmName()
        end
        
        table.insert(results, {
            name = name,
            fullName = name .. "-" .. realm,
            unit = nil,
            source = "search",
            realm = realm
        })
    end
    
    -- Display search results
    self.searchResultsFrame:Show()
    self.searchResultsFrame:DisplayResults(results, function(result)
        self:SelectSearchResult(result)
    end)
end

-- Select a search result
function DR:SelectSearchResult(result)
    if not result then return end
    
    self:Debug("Selected search result: " .. result.name, "driver")
    
    -- Store selection
    self.selectedDriver = result.fullName
    self.selectedDriverName = result.name
    self.selectedDriverUnit = result.unit
    
    -- Update portrait and info
    if result.unit then
        -- If player is in group, use their unit ID
        self:UpdateDriverInfo(result.unit)
    else
        -- Otherwise, use cached data
        self:UpdateDriverInfoByName(result.name, result.realm or GetRealmName())
    end
    
    -- Close the results frame after selection
    self.searchResultsFrame:Hide()
    
    -- Store in search history if it's a new entry
    if not DriverReviewDB.searchHistory then
        DriverReviewDB.searchHistory = {}
    end
    
    DriverReviewDB.searchHistory[result.fullName] = {
        name = result.name,
        fullName = result.fullName,
        realm = result.realm or GetRealmName(),
        lastSearched = time()
    }
end

-- Update driver information with unit ID
function DR:UpdateDriverInfo(unit)
    if not unit then
        self.driverNameText:SetText("Select a driver")
        self.driverInfoText:SetText("to review")
        self.portraitFrame:UpdatePortrait(nil)
        return
    end
    
    -- Update portrait
    self.portraitFrame:UpdatePortrait(unit)
    
    local success, result = pcall(function()
        -- Get all the character info
        local name = UnitName(unit) or "Unknown"
        local _, class = UnitClass(unit)
        local level = UnitLevel(unit)
        local race = UnitRace(unit)
        
        -- Set the player name in the name field (larger font)
        self.driverNameText:SetText(name)
        
        -- Format the additional info text
        local infoText = ""
        
        -- Add class with color
        if class and class ~= "" then
            -- Add class color if possible
            local classColor = RAID_CLASS_COLORS[select(2, UnitClass(unit))]
            if classColor then
                infoText = "|c" .. classColor.colorStr .. class .. "|r"
            else
                infoText = class
            end
        end
        
        -- Add race and level formatted together
        local raceLevel = ""
        if race and race ~= "" then
            raceLevel = race
        end
        
        if level and level > 0 then
            if raceLevel ~= "" then
                raceLevel = raceLevel .. " - Level " .. level
            else
                raceLevel = "Level " .. level
            end
        end
        
        if raceLevel ~= "" then
            if infoText ~= "" then infoText = infoText .. "\n" end
            infoText = infoText .. "|cFFAAAAAA" .. raceLevel .. "|r"
        end
        
        return infoText
    end)
    
    if success then
        self.driverInfoText:SetText(result)
    else
        self.driverInfoText:SetText("Error loading driver info")
    end
    
    -- Store player data for future use
    self.DataStore:StorePlayerData(unit, UnitName(unit) .. "-" .. (select(2, UnitFullName(unit)) or GetRealmName()))
end

-- Update driver info with just a name
function DR:UpdateDriverInfoByName(playerName, realm)
    if not playerName then return end
    
    realm = realm or GetRealmName()
    local fullName = playerName .. "-" .. realm
    
    -- Update portrait
    self.portraitFrame:UpdateByName(playerName, realm)
    
    -- Set driver name
    self.driverNameText:SetText(playerName)
    
    -- Try to get class info from cached data
    local infoText = ""
    
    -- Add realm if different from player's
    if realm ~= GetRealmName() then
        infoText = "|cFFAAAAAA" .. realm .. "|r"
    end
    
    -- Try to get class info from cached data if available
    local playerData = self.DataStore:GetPlayerData(fullName)
    if playerData and playerData.class then
        if infoText ~= "" then infoText = infoText .. "\n" end
        
        -- Try to get class color
        if playerData.classFileName and RAID_CLASS_COLORS[playerData.classFileName] then
            local classColor = RAID_CLASS_COLORS[playerData.classFileName]
            infoText = infoText .. "|c" .. classColor.colorStr .. playerData.class .. "|r"
        else
            infoText = infoText .. playerData.class
        end
        
        -- Add race and level if available
        local raceLevel = ""
        if playerData.race then
            raceLevel = playerData.race
        end
        
        if playerData.level and playerData.level > 0 then
            if raceLevel ~= "" then
                raceLevel = raceLevel .. " - Level " .. playerData.level
            else
                raceLevel = "Level " .. playerData.level
            end
        end
        
        if raceLevel ~= "" then
            if infoText ~= "" then infoText = infoText .. "\n" end
            infoText = infoText .. "|cFFAAAAAA" .. raceLevel .. "|r"
        end
    end
    
    -- Set info text
    self.driverInfoText:SetText(infoText)
end

-- Update the My Ratings tab
function DR:UpdateMyRatings()
    -- Release all current frames
    self.ratingCardPool:ReleaseAll()
    
    -- Get all ratings I've given
    local allRatings = self.DataStore:GetAllMyRatings()
    
    -- Create rating entries
    local yOffset = 10
    for i, rating in ipairs(allRatings) do
        local frame = self.ratingCardPool:Acquire()
        frame:SetSize(260, 100)
        frame:SetPoint("TOPLEFT", 10, -yOffset)
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 12,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        frame:SetBackdropColor(0.1, 0.1, 0.1, 0.6)
        
        -- Driver name
        if not frame.nameText then
            frame.nameText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            frame.nameText:SetPoint("TOPLEFT", 10, -10)
        end
        frame.nameText:SetText(rating.driverName or "Unknown")
        
        -- Add delete button if needed
        if not frame.deleteButton then
            frame.deleteButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
            frame.deleteButton:SetSize(24, 24)
            frame.deleteButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
            frame.deleteButton:SetScript("OnClick", function()
                -- Remove this rating from the database
                self.DataStore:DeleteMyRating(rating)
                -- Update the display
                self:UpdateMyRatings()
                -- Show notification
                self:ShowNotification("Rating deleted")
            end)
        end
        
        -- Review date
        if not frame.dateText then
            frame.dateText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            frame.dateText:SetPoint("TOPLEFT", 10, -30)
        end
        frame.dateText:SetText("Reviewed: " .. date("%m/%d/%y", rating.timestamp or time()))
        
        -- Rating stars
        if not frame.starsContainer then
            frame.starsContainer = CreateFrame("Frame", nil, frame)
            frame.starsContainer:SetSize(120, 24)
            frame.starsContainer:SetPoint("TOPLEFT", 10, -50)
            
            frame.stars = {}
            for j = 1, 5 do
                local star = frame.starsContainer:CreateTexture(nil, "ARTWORK")
                star:SetSize(20, 20)
                star:SetPoint("LEFT", (j-1)*22, 0)
                frame.stars[j] = star
            end
            
            if not frame.starText then
                frame.starText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                frame.starText:SetPoint("LEFT", frame.starsContainer, "RIGHT", 10, 0)
            end
        end
        
        -- Update stars
        local ratingValue = rating.rating or 0
        for j = 1, 5 do
            if j <= ratingValue then
                frame.stars[j]:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-Ready")
                frame.stars[j]:SetVertexColor(COLORS.STAR_ACTIVE[1], COLORS.STAR_ACTIVE[2], COLORS.STAR_ACTIVE[3], COLORS.STAR_ACTIVE[4])
            else
                frame.stars[j]:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
                frame.stars[j]:SetVertexColor(COLORS.STAR_INACTIVE[1], COLORS.STAR_INACTIVE[2], COLORS.STAR_INACTIVE[3], COLORS.STAR_INACTIVE[4])
            end
        end
        
        frame.starText:SetText(ratingValue .. " star" .. (ratingValue ~= 1 and "s" or ""))
        frame.starText:SetTextColor(1, 0.82, 0, 1)
        
        -- Comment
        if not frame.commentText then
            frame.commentText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            frame.commentText:SetPoint("TOPLEFT", 10, -75)
            frame.commentText:SetWidth(240)
        end
        frame.commentText:SetText(rating.comment or "")
        
        frame:Show()
        yOffset = yOffset + 110  -- Spacing between entries
    end
    
    -- Set scroll child height
    self.myRatingsScrollChild:SetHeight(math.max(300, yOffset))
end

-- Update the My Reviews tab
function DR:UpdateMyReviews()
    -- Release all current frames
    self.reviewCardPool:ReleaseAll()
    
    -- Calculate overall rating
    local myReviews = self.DataStore:GetReviewsForPlayer(DR.fullPlayerName)
    local totalRating = 0
    local ratingCount = #myReviews
    
    for _, review in ipairs(myReviews) do
        totalRating = totalRating + (review.rating or 0)
    end
    
    local overallRating = ratingCount > 0 and (totalRating / ratingCount) or 0
    self.overallRatingText:SetText(string.format("Overall Rating: %.1f (%d reviews)", overallRating, ratingCount))
    
    -- Update overall stars
    for i = 1, 5 do
        if i <= math.floor(overallRating + 0.5) then -- Round to nearest
            self.overallStars[i]:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-Ready")
            self.overallStars[i]:SetVertexColor(COLORS.STAR_ACTIVE[1], COLORS.STAR_ACTIVE[2], COLORS.STAR_ACTIVE[3], COLORS.STAR_ACTIVE[4])
        else
            self.overallStars[i]:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
            self.overallStars[i]:SetVertexColor(COLORS.STAR_INACTIVE[1], COLORS.STAR_INACTIVE[2], COLORS.STAR_INACTIVE[3], COLORS.STAR_INACTIVE[4])
        end
    end
    
    -- Sort by timestamp (newest first)
    table.sort(myReviews, function(a, b)
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)
    
    -- Adjust the starting position to account for overall stars
    local yOffset = 40
    
    -- Create review entries
    for _, review in ipairs(myReviews) do
        local frame = self.reviewCardPool:Acquire()
        frame:SetSize(260, 120)
        frame:SetPoint("TOPLEFT", 10, -yOffset)
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 12,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        frame:SetBackdropColor(0.1, 0.1, 0.1, 0.6)
        
        -- Store the review data in the frame for deletion
        frame.reviewData = review
        
        -- Add delete button
        if not frame.deleteButton then
            frame.deleteButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
            frame.deleteButton:SetSize(24, 24)
            frame.deleteButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
            frame.deleteButton:SetScript("OnClick", function()
                -- Remove this review from the database
                if self.DataStore:DeleteReview(review) then
                    -- Update the display
                    self:UpdateMyReviews()
                    -- Show notification
                    self:ShowNotification("Review deleted", "success")
                end
            end)
        end
        
        -- Create reviewer portrait
        if not frame.portraitFrame then
            frame.portraitFrame = self:CreatePortraitFrame(frame)
            frame.portraitFrame:SetSize(64, 64)
            frame.portraitFrame:SetPoint("TOPLEFT", 10, -10)
        end
        
        -- Get reviewer info
        local reviewerName, reviewerRealm = "Unknown", GetRealmName()
        if review.reviewer then
            reviewerName, reviewerRealm = review.reviewer:match("([^-]+)-?(.*)")
            if not reviewerRealm or reviewerRealm == "" then
                reviewerRealm = GetRealmName()
            end
        end
        
        -- Update portrait
        frame.portraitFrame:UpdateByName(reviewerName, reviewerRealm)
        
        -- Reviewer name
        if not frame.nameText then
            frame.nameText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            frame.nameText:SetPoint("TOPLEFT", frame.portraitFrame, "TOPRIGHT", 10, -5)
            frame.nameText:SetPoint("RIGHT", frame, "RIGHT", -35, 0)
            frame.nameText:SetJustifyH("LEFT")
        end
        frame.nameText:SetText(reviewerName)
        
        -- Rating stars
        if not frame.starContainer then
            frame.starContainer = CreateFrame("Frame", nil, frame)
            frame.starContainer:SetSize(120, 24)
            frame.starContainer:SetPoint("TOPLEFT", frame.portraitFrame, "TOPRIGHT", 10, -30)
            
            frame.stars = {}
            for j = 1, 5 do
                local star = frame.starContainer:CreateTexture(nil, "ARTWORK")
                star:SetSize(18, 18)
                star:SetPoint("LEFT", (j-1)*20, 0)
                frame.stars[j] = star
            end
            
            if not frame.starText then
                frame.starText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                frame.starText:SetPoint("LEFT", frame.starContainer, "RIGHT", 5, 0)
            end
        end
        
        -- Update stars
        local ratingValue = review.rating or 0
        for j = 1, 5 do
            if j <= ratingValue then
                frame.stars[j]:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-Ready")
                frame.stars[j]:SetVertexColor(COLORS.STAR_ACTIVE[1], COLORS.STAR_ACTIVE[2], COLORS.STAR_ACTIVE[3], COLORS.STAR_ACTIVE[4])
            else
                frame.stars[j]:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
                frame.stars[j]:SetVertexColor(COLORS.STAR_INACTIVE[1], COLORS.STAR_INACTIVE[2], COLORS.STAR_INACTIVE[3], COLORS.STAR_INACTIVE[4])
            end
        end
        
        frame.starText:SetText(ratingValue .. " star" .. (ratingValue ~= 1 and "s" or ""))
        frame.starText:SetTextColor(1, 0.82, 0, 1)
        
        -- Review date
        if not frame.dateText then
            frame.dateText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            frame.dateText:SetPoint("TOPLEFT", frame.portraitFrame, "BOTTOMLEFT", 0, -5)
        end
        frame.dateText:SetText("Reviewed: " .. date("%m/%d/%y", review.timestamp or time()))
        
        -- Comment
        if not frame.commentText then
            frame.commentText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            frame.commentText:SetPoint("TOPLEFT", frame.dateText, "BOTTOMLEFT", 0, -5)
            frame.commentText:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
            frame.commentText:SetJustifyH("LEFT")
            frame.commentText:SetWidth(240)
        end
        frame.commentText:SetText(review.comment or "")
        
        frame:Show()
        yOffset = yOffset + 130
    end
    
    -- Set scroll child height
    self.myReviewsScrollChild:SetHeight(math.max(300, yOffset))
end

-- Submit a review
function DR:SubmitReview()
    -- Validate driver selection
    if not self.selectedDriver then
        self:Debug("Cannot submit review: No driver selected", "rating")
        self:ShowNotification("Please search and select a driver to rate", "error")
        return false
    end
    
    -- Validate rating selection
    if not self.currentRating or self.currentRating < 1 or self.currentRating > 5 then
        self:Debug("Cannot submit review: Invalid rating value: " .. tostring(self.currentRating), "rating")
        self:ShowNotification("Please select a rating (1-5 stars)", "error")
        return false
    end
    
    -- Get comment text with validation
    local commentText = self.commentEditBox:GetText() or ""
    
    -- Create review object
    local review = {
        driver = self.selectedDriver,
        driverName = self.selectedDriverName,
        reviewer = DR.fullPlayerName,
        rating = self.currentRating,
        comment = commentText,
        timestamp = time()
    }
    
    -- Save review to local database
    self.DataStore:AddMyRating(self.selectedDriver, review)
    
    -- Try to gather player data for future use
    if self.selectedDriverUnit then
        self.DataStore:StorePlayerData(self.selectedDriverUnit, self.selectedDriver)
    end
    
    -- Send review to target player if they're in the group
    self:SendReview(review)
    
    -- Reset form
    self:ResetReviewForm()
    
    -- Show confirmation
    self:ShowNotification("Review submitted!")
    
    -- Update the My Ratings tab if it's visible
    if self.currentTab == 2 then
        self:UpdateMyRatings()
    end
    
    return true
end

-- Reset the review form
function DR:ResetReviewForm()
    self.currentRating = nil
    
    -- Reset stars display
    self.ratingStars:SetRating(0)
    
    -- Clear the comment box
    self.commentEditBox:SetText("")
    
    -- Clear search box but don't reset selection
    self.searchEditBox:SetText("")
end

-- Receive a review from another player
function DR:ReceiveReview(review, sender)
    -- Validate input
    if not review or not sender or sender == "" then
        return
    end
    
    -- Verify this review is for me
    if not review.driver or review.driver ~= DR.fullPlayerName then
        return
    end
    
    -- Validate review fields
    if not review.rating or review.rating < 1 or review.rating > 5 then
        return
    end
    
    -- Initialize storage if needed
    if not DriverReviewDB.ratings[DR.fullPlayerName] then
        DriverReviewDB.ratings[DR.fullPlayerName] = {}
    end
    
    -- Add sender information if not present
    review.reviewer = review.reviewer or sender
    
    -- Store reviewer information for future searches
    self.DataStore:StoreReviewerInfo(review.reviewer)
    
    -- Find existing review from this reviewer and remove it (to prevent multiple reviews)
    local existingIndex = nil
    for i, existingReview in ipairs(DriverReviewDB.ratings[DR.fullPlayerName]) do
        if existingReview.reviewer == review.reviewer then
            existingIndex = i
            break
        end
    end
    
    -- Determine if this is a new review or an update
    local isNewReview = (existingIndex == nil)
    
    -- Remove existing review if found
    if existingIndex then
        table.remove(DriverReviewDB.ratings[DR.fullPlayerName], existingIndex)
    end
    
    -- Check for missing timestamp
    if not review.timestamp then
        review.timestamp = time()
    end
    
    -- Sanitize comment
    if type(review.comment) ~= "string" then
        review.comment = tostring(review.comment or "")
    end
    
    -- Store the review
    table.insert(DriverReviewDB.ratings[DR.fullPlayerName], review)
    
    -- Play sound alert for new review
    if isNewReview then
        PlaySound(SOUNDS.NEW_REVIEW)
        FlashClientIcon()
    end
    
    -- Show notification
    self:ShowNotification("New driver review received!", "success")
    
    -- Update the My Reviews tab if it's visible
    if self.currentTab == 3 then
        self:UpdateMyReviews()
    end
end

-- Send a review to the target player
function DR:SendReview(review)
    -- Verify we have everything needed
    if not review then return false end
    
    -- Create message
    local message = {
        type = "review",
        review = review
    }
    
    -- Serialize the review data
    local serializedMessage = self:SerializeMessage(message)
    
    -- Check message length (addon messages have size limits)
    if #serializedMessage > 255 then
        -- Truncate comment if too long
        if review.comment and #review.comment > 100 then
            review.comment = review.comment:sub(1, 100) .. "..."
            -- Try again with shortened comment
            return self:SendReview(review)
        end
        return false
    end
    
    -- First check if the target player is in group
    local targetInGroup = false
    local groupMembers = self:GetGroupMembers()
    for _, member in ipairs(groupMembers) do
        if member.fullName == review.driver then
            targetInGroup = true
            break
        end
    end
    
    if targetInGroup then
        -- Send the message to group channel
        local channel = IsInRaid() and "RAID" or "PARTY"
        local sent = C_ChatInfo.SendAddonMessage(DR.addonMessagePrefix, serializedMessage, channel)
        return sent
    else
        -- Not in group, save locally only
        return true
    end
end

-- Handle addon messages
function DR:OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= DR.addonMessagePrefix then return end
    if sender == DR.fullPlayerName then return end  -- Ignore messages from self
    
    local data = self:DeserializeMessage(message)
    if not data then return end
    
    -- Handle different message types
    if data.type == "review" and data.review then
        self:ReceiveReview(data.review, sender)
    end
end

-- Handle slash commands
function DR:HandleSlashCommand(msg)
    local args = {}
    for arg in msg:gmatch("%S+") do
        table.insert(args, arg)
    end
    
    -- Basic debug toggle
    if args[1] == "debug" then
        if args[2] == "on" then
            DriverReviewDB.debug = true
        elseif args[2] == "off" then
            DriverReviewDB.debug = false
        else
            DriverReviewDB.debug = not DriverReviewDB.debug
        end
        print("|cFF00CCFF[DriverReview]|r Debug mode " .. (DriverReviewDB.debug and "enabled" or "disabled"))
        return
    end
    
    -- Debug console
    if args[1] == "console" then
        if not self.debugFrame then
            self:CreateDebugFrame()
        end
        
        if self.debugFrame:IsShown() then
            self.debugFrame:Hide()
        else
            self.debugFrame:Show()
        end
        return
    end
    
    -- Toggle main frame
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
    end
end

-- Create debug frame
function DR:CreateDebugFrame()
    if self.debugFrame then return self.debugFrame end
    
    -- Create frame
    self.debugFrame = self:CreateStandardFrame(UIParent, 500, 400, "DriverReview Debug Console")
    self.debugFrame:SetPoint("CENTER")
    self.debugFrame:SetMovable(true)
    self.debugFrame:EnableMouse(true)
    self.debugFrame:RegisterForDrag("LeftButton")
    self.debugFrame:SetScript("OnDragStart", self.debugFrame.StartMoving)
    self.debugFrame:SetScript("OnDragStop", self.debugFrame.StopMovingOrSizing)
    self.debugFrame:Hide()
    
    -- Close button
    local closeButton = CreateFrame("Button", nil, self.debugFrame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -5, -5)
    
    -- Debug category toggles
    local categories = {"general", "driver", "portrait", "rating", "comment", "dropdown"}
    local checkboxes = {}
    
    for i, category in ipairs(categories) do
        local checkbox = CreateFrame("CheckButton", nil, self.debugFrame, "UICheckButtonTemplate")
        checkbox:SetPoint("TOPLEFT", 20, -40 - (i-1)*25)
        checkbox:SetChecked(DriverReviewDB.debugCategories and DriverReviewDB.debugCategories[category] or true)
        checkbox.category = category
        
        local label = checkbox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", checkbox, "RIGHT", 5, 0)
        label:SetText(category:gsub("^%l", string.upper))
        
        checkbox:SetScript("OnClick", function(self)
            if not DriverReviewDB.debugCategories then
                DriverReviewDB.debugCategories = {}
            end
            DriverReviewDB.debugCategories[category] = self:GetChecked()
            DR:Debug("Toggled " .. category .. " debugging: " .. (self:GetChecked() and "ON" or "OFF"))
        end)
        
        checkboxes[category] = checkbox
    end
    
    -- Debug messages scrollframe
    local scrollFrame = CreateFrame("ScrollFrame", nil, self.debugFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetSize(440, 250)
    scrollFrame:SetPoint("TOPLEFT", 20, -180)
    
    local scrollChild = CreateFrame("Frame")
    scrollFrame:SetScrollChild(scrollChild)
    scrollChild:SetSize(440, 500)
    
    self.debugScrollFrame = scrollFrame
    self.debugScrollChild = scrollChild
    self.debugMessages = {}
    
    -- Clear button
    local clearButton = self:CreateButton(self.debugFrame, 80, 25, "Clear", function()
        for _, msg in ipairs(self.debugMessages) do
            msg:Hide()
        end
        wipe(self.debugMessages)
    end)
    clearButton:SetPoint("BOTTOMLEFT", 20, 20)
    
    -- Status button
    local statusButton = self:CreateButton(self.debugFrame, 120, 25, "Show Status", function()
        self:ShowVariableStates()
    end)
    statusButton:SetPoint("BOTTOMRIGHT", -20, 20)
    
    return self.debugFrame
end

-- Add a message to the debug frame
function DR:AddDebugMessage(message)
    if not self.debugScrollChild then return end
    
    local msg = self.debugScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    msg:SetPoint("TOPLEFT", 5, -5 - (#self.debugMessages * 20))
    msg:SetWidth(430)
    msg:SetJustifyH("LEFT")
    msg:SetText(message)
    
    table.insert(self.debugMessages, msg)
    
    -- Limit number of messages
    if #self.debugMessages > 100 then
        self.debugMessages[1]:Hide()
        table.remove(self.debugMessages, 1)
        
        -- Reposition remaining messages
        for i, msg in ipairs(self.debugMessages) do
            msg:SetPoint("TOPLEFT", 5, -5 - ((i-1) * 20))
        end
    end
    
    -- Scroll to bottom
    self.debugScrollFrame:UpdateScrollChildRect()
    self.debugScrollFrame:SetVerticalScroll(self.debugScrollFrame:GetVerticalScrollRange())
end

-- Show current variable states
function DR:ShowVariableStates()
    self:Debug("---------- VARIABLE STATES ----------", "general")
    self:Debug("selectedDriver: " .. tostring(self.selectedDriver), "general")
    self:Debug("selectedDriverName: " .. tostring(self.selectedDriverName), "general")
    self:Debug("selectedDriverUnit: " .. tostring(self.selectedDriverUnit), "general")
    self:Debug("currentRating: " .. tostring(self.currentRating), "general")
    
    if self.portraitFrame and self.portraitFrame.portraitTexture then
        self:Debug("Portrait texture exists", "general")
    else
        self:Debug("Portrait texture missing", "general")
    end
    
    if self.commentEditBox then
        self:Debug("Comment box text: " .. tostring(self.commentEditBox:GetText()), "general")
    end
    
    self:Debug("-----------------------------------", "general")
end

-- Initialize addon
function DR:Initialize()
    -- Register addon message prefix
    C_ChatInfo.RegisterAddonMessagePrefix(DR.addonMessagePrefix)
    
    -- Create main frame
    self:CreateMainFrame()
    
    -- Register events
    local eventFrame = CreateFrame("Frame")
    self.eventFrame = eventFrame  -- Use separate variable for events
    eventFrame:RegisterEvent("PLAYER_LOGIN")
    eventFrame:RegisterEvent("CHAT_MSG_ADDON")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ADDON_LOADED")
    
    -- Set up event handler with error catching
    eventFrame:SetScript("OnEvent", function(frame, event, ...)
        if event == "PLAYER_LOGIN" then
            self:OnPlayerLogin()
        elseif event == "CHAT_MSG_ADDON" then
            self:OnAddonMessage(...)
        elseif event == "GROUP_ROSTER_UPDATE" then
            if self.searchResultsFrame and self.searchResultsFrame:IsShown() then
                self:SearchDriver(self.searchEditBox:GetText())
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            self:Debug("PLAYER_ENTERING_WORLD event received", "general")
        elseif event == "ADDON_LOADED" and ... == "DriverReview" then
            self:Debug("ADDON_LOADED event received for DriverReview", "general")
        end
    end)
    
    -- Add slash command
    SLASH_DRIVERREVIEW1 = "/driverreview"
    SLASH_DRIVERREVIEW2 = "/dr"
    SlashCmdList["DRIVERREVIEW"] = function(msg)
        self:HandleSlashCommand(msg)
    end
    
    -- Add slash command to check addon status
    SLASH_DRCHECK1 = "/drcheck"
    SlashCmdList["DRCHECK"] = function()
        self:ShowVariableStates()
    end
end

-- Handle player login
function DR:OnPlayerLogin()
    -- Initialize saved variables if needed
    DriverReviewDB = DriverReviewDB or {}
    DriverReviewDB.ratings = DriverReviewDB.ratings or {}
    DriverReviewDB.myRatings = DriverReviewDB.myRatings or {}
    DriverReviewDB.searchHistory = DriverReviewDB.searchHistory or {}
    DriverReviewDB.reviewerHistory = DriverReviewDB.reviewerHistory or {}
    DriverReviewDB.playerData = DriverReviewDB.playerData or {}
    DriverReviewDB.debug = DriverReviewDB.debug or false
    DriverReviewDB.debugCategories = DriverReviewDB.debugCategories or {
        general = true,
        driver = true,
        portrait = true,
        rating = true,
        comment = true,
        dropdown = true
    }
    
    -- Show welcome message
    print("|cFF00CCFF[DriverReview]|r Addon loaded (v" .. DR.version .. "). Type |cFFFFFFFF/dr|r to open or |cFFFFFFFF/dr debug|r for debugging options.")
end

-- Initialize the addon
DR:Initialize()