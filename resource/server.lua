local dbConn = nil
local billboards = {}
local adsAll = {}
local ads = {}
local adsById = {}
local adImageCache = {}
local urlPreviewCache = {}
local urlPreviewCacheBytes = 0
local urlPreviewCacheClock = 0
local previewInFlight = {}
local previewQueued = {}
local latestPreviewRequest = {}
local previewFetchActive = 0
local PREVIEW_FETCH_LIMIT = 4
local PREVIEW_QUEUE_LIMIT = 32
local readyPlayers = {}
local playerAdCache = {}
local submitPending = {}
local rateLimits = { sync = {}, submit = {}, adminList = {}, adminAction = {}, billboardAction = {}, preview = {}, interact = {} }

local currentAdIndex = 1
local rotationTimer = nil
local adsPed = nil

local STATUS_INACTIVE = 0
local STATUS_ACTIVE   = 1
local STATUS_PENDING  = 2
local STATUS_REJECTED = 3

local ACTION_COOLDOWN = 600
local SYNC_COOLDOWN   = 1500

local HTTP_HEADERS = {
    ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    ["Accept"] = "image/png,image/jpeg,*/*;q=0.8"
}

local function watchRemoteResponseSize(requestHandle, maxBytes, onExceeded)
    if not requestHandle or type(getRemoteRequestInfo) ~= "function" or type(abortRemoteRequest) ~= "function" then
        return nil
    end
    local exceeded = false
    local stopped = false
    local timer
    local interval = math.max(50, math.min(500, tonumber(Config.ImageSizeCheckIntervalMs) or 100))
    local function stop()
        stopped = true
        if isTimer(timer) then killTimer(timer) end
        timer = nil
        return exceeded
    end
    timer = setTimer(function()
        if stopped then return end
        local info = getRemoteRequestInfo(requestHandle)
        if type(info) ~= "table" then
            stop()
            return
        end
        local received = tonumber(info.bytesReceived) or 0
        local total = tonumber(info.bytesTotal) or 0
        if received > maxBytes or total > maxBytes then
            exceeded = true
            stop()
            if onExceeded then onExceeded() end
            abortRemoteRequest(requestHandle)
        end
    end, interval, 0)
    return stop
end

local function getNow()
    return getRealTime().timestamp
end

local function isRateLimited(bucket, player, cooldown)
    if not isElement(player) then return true end
    local now = getTickCount()
    local last = rateLimits[bucket][player]
    if last and (now - last) < (cooldown or ACTION_COOLDOWN) then
        return true
    end
    rateLimits[bucket][player] = now
    return false
end

local function getPlayerIdentifier(player)
    if not isElement(player) then return "Unknown" end
    local acc = getPlayerAccount(player)
    if acc and not isGuestAccount(acc) then
        return getAccountName(acc)
    end
    return "serial:" .. tostring(getPlayerSerial(player))
end

local function getPlayerDisplayName(player)
    if not isElement(player) then return "Unknown" end
    local acc = getPlayerAccount(player)
    if acc and not isGuestAccount(acc) then
        return getAccountName(acc)
    end
    return getPlayerName(player):gsub("#%x%x%x%x%x%x", "")
end

local function isPlayerInACLList(player, groupList)
    if not isElement(player) or getElementType(player) ~= "player" then return false end
    local acc = getPlayerAccount(player)
    if not acc or isGuestAccount(acc) then return false end
    local objName = "user." .. getAccountName(acc)
    for _, groupName in ipairs(groupList or {}) do
        local group = aclGetGroup(groupName)
        if group and isObjectInACLGroup(objName, group) then
            return true
        end
    end
    return false
end

local function hasBuilderPermission(player)
    return isPlayerInACLList(player, Config.AdminACLGroups) or hasObjectPermissionTo(player, "command.kick", false)
end

local function hasModeratorPermission(player)
    return isPlayerInACLList(player, Config.ModeratorACLGroups) or hasBuilderPermission(player)
end

local function finiteNumber(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end

local function validateBillboardPlacement(x, y, z, rz, interior, dimension)
    x, y, z = finiteNumber(x), finiteNumber(y), finiteNumber(z)
    rz = finiteNumber(rz or 0)
    interior = finiteNumber(interior or 0)
    dimension = finiteNumber(dimension or 0)
    if not x or not y or not z or not rz or not interior or not dimension then
        return false, "Enter valid numeric coordinates and world settings."
    end
    if x < -3000 or x > 3000 or y < -3000 or y > 3000 or z < -1000 or z > 2000 then
        return false, "Coordinates are outside the supported world limits."
    end
    if rz < 0 or rz > 360 then return false, "Rotation must be between 0 and 360 degrees." end
    if interior < 0 or interior > 255 or interior % 1 ~= 0 then return false, "Interior must be an integer between 0 and 255." end
    if dimension < 0 or dimension > 65535 or dimension % 1 ~= 0 then return false, "Dimension must be an integer between 0 and 65535." end
    return true, x, y, z, rz % 360, interior, dimension
end

local function isNearAdsPed(player)
    if not isElement(player) then return false end
    if hasModeratorPermission(player) then return true end
    if not Config.Ped or not Config.Ped.Enabled then return true end
    if not isElement(adsPed) then return false end
    local px, py, pz = getElementPosition(player)
    local ex, ey, ez = getElementPosition(adsPed)
    return getDistanceBetweenPoints3D(px, py, pz, ex, ey, ez) <= (Config.Ped.InteractionDistance or 4.5) + 2.0
end

local function sanitizeImageUrl(rawUrl)
    if type(rawUrl) ~= "string" then return "" end
    local s = rawUrl:match("^%s*(.-)%s*$") or ""
    s = s:match("^(%S+)") or ""
    if s == "" or #s > (Config.MaxUrlLength or 300) or s:find("[%c%s]") then return "" end
    local scheme, rest = s:match("^([%a][%w+%.%-]*)://(.*)$")
    if scheme then
        scheme = scheme:lower()
        if scheme ~= "http" and scheme ~= "https" then return "" end
        return scheme .. "://" .. rest
    end
    if s:find("://", 1, true) then return "" end
    return "https://" .. s
end

local function extractHost(url)
    if type(url) ~= "string" then return nil end
    local scheme, authority = url:match("^(https?)://([^/%?#]+)")
    if not scheme or not authority or authority == "" then return nil end
    if authority:find("@", 1, true) or authority:find(":", 1, true) then return nil end
    local host = authority:lower():gsub("%.$", ""):gsub("^www%.", "")
    if host == "" or #host > 253 or host:find("[^%w%.%-]") or host:find("..", 1, true) then return nil end
    if host:match("^%.") or host:match("%.$") then return nil end
    for label in host:gmatch("[^%.]+") do
        if #label > 63 or label:match("^%-") or label:match("%-$") then return nil end
    end
    return host
end

local function isPrivateHost(host)
    if not host or host == "localhost" or host:sub(-10) == ".localhost" or host:sub(-6) == ".local" or host:sub(-9) == ".internal" then
        return true
    end
    if not host:find("%.") or host:match("^[%d%.]+$") or host:match("^0x[%da-f]+$") or host:match("^0x[%da-f]+[%.%d]+$") then return true end
    return false
end

local function hasValidImageExtension(url)
    local pathOnly = url:match("^https?://[^/%?#]+([^%?#]*)") or ""
    local ext = pathOnly:lower():match("%.([%a%d]+)$")
    return ext == "png" or ext == "jpg" or ext == "jpeg"
end

local function readUInt16(data, position)
    local high, low = data:byte(position, position + 1)
    if not high or not low then return nil end
    return high * 256 + low
end

local function readUInt32(data, position)
    local a, b, c, d = data:byte(position, position + 3)
    if not a or not b or not c or not d then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local JPEG_START_OF_FRAME = {
    [0xC0] = true, [0xC1] = true, [0xC2] = true, [0xC3] = true,
    [0xC5] = true, [0xC6] = true, [0xC7] = true, [0xC9] = true,
    [0xCA] = true, [0xCB] = true, [0xCD] = true, [0xCE] = true, [0xCF] = true
}

local function detectImageFormat(binaryData)
    local maxBytes = tonumber(Config.MaxImageBytes) or (2 * 1024 * 1024)
    if type(binaryData) ~= "string" or #binaryData < 24 or #binaryData > maxBytes then return nil end
    local ext, width, height
    if binaryData:sub(1, 8) == "\137PNG\r\n\26\n" and binaryData:sub(9, 12) == "\0\0\0\13" and binaryData:sub(13, 16) == "IHDR" and binaryData:sub(-12, -9) == "\0\0\0\0" and binaryData:sub(-8, -5) == "IEND" then
        ext = "png"
        width = readUInt32(binaryData, 17)
        height = readUInt32(binaryData, 21)
    elseif binaryData:byte(1) == 0xFF and binaryData:byte(2) == 0xD8 and binaryData:byte(3) == 0xFF then
        local position = 3
        local length = #binaryData
        while position < length - 8 do
            local markerStart = binaryData:find("\255", position, true)
            if not markerStart or markerStart >= length - 8 then break end
            local marker = binaryData:byte(markerStart + 1)
            while marker == 0xFF do
                markerStart = markerStart + 1
                marker = binaryData:byte(markerStart + 1)
            end
            if not marker then break end
            if marker == 0xD8 or marker == 0xD9 or (marker >= 0xD0 and marker <= 0xD7) or marker == 0x01 then
                position = markerStart + 2
            else
                local segmentLength = readUInt16(binaryData, markerStart + 2)
                if not segmentLength or segmentLength < 2 or markerStart + segmentLength + 1 > length then break end
                if JPEG_START_OF_FRAME[marker] then
                    height = readUInt16(binaryData, markerStart + 5)
                    width = readUInt16(binaryData, markerStart + 7)
                    ext = "jpg"
                    break
                end
                position = markerStart + segmentLength + 2
            end
        end
    end
    if not ext or not width or not height or width < 1 or height < 1 then return nil end
    local maxWidth = tonumber(Config.MaxImageWidth) or 4096
    local maxHeight = tonumber(Config.MaxImageHeight) or 4096
    local maxPixels = tonumber(Config.MaxImagePixels) or (8 * 1024 * 1024)
    if width > maxWidth or height > maxHeight or width * height > maxPixels then return nil end
    return ext
end

local function toDataUri(binaryData, ext)
    local mime = (ext == "jpg" or ext == "jpeg") and "image/jpeg" or "image/png"
    return "data:" .. mime .. ";base64," .. encodeString("base64", binaryData)
end

local function getCachedPreview(url)
    local entry = urlPreviewCache[url]
    if not entry then return nil end
    urlPreviewCacheClock = urlPreviewCacheClock + 1
    entry.lastUsed = urlPreviewCacheClock
    return entry.dataUri
end

local function cachePreview(url, dataUri)
    local bytes = #dataUri
    local maxBytes = tonumber(Config.MaxPreviewCacheBytes) or (8 * 1024 * 1024)
    local maxEntries = math.max(1, tonumber(Config.MaxPreviewCacheEntries) or 12)
    if bytes > maxBytes then return end
    local existing = urlPreviewCache[url]
    if existing then
        urlPreviewCacheBytes = urlPreviewCacheBytes - existing.bytes
        urlPreviewCache[url] = nil
    end
    local entryCount = 0
    for _ in pairs(urlPreviewCache) do entryCount = entryCount + 1 end
    while urlPreviewCacheBytes + bytes > maxBytes or entryCount >= maxEntries do
        local oldestUrl, oldestTick
        for key, entry in pairs(urlPreviewCache) do
            if not oldestTick or entry.lastUsed < oldestTick then
                oldestUrl, oldestTick = key, entry.lastUsed
            end
        end
        if not oldestUrl then break end
        urlPreviewCacheBytes = urlPreviewCacheBytes - urlPreviewCache[oldestUrl].bytes
        urlPreviewCache[oldestUrl] = nil
        entryCount = entryCount - 1
    end
    urlPreviewCacheClock = urlPreviewCacheClock + 1
    urlPreviewCache[url] = { dataUri = dataUri, bytes = bytes, lastUsed = urlPreviewCacheClock }
    urlPreviewCacheBytes = urlPreviewCacheBytes + bytes
end

local function isDomainAllowed(host)
    if not host or isPrivateHost(host) then return false end
    if not Config.EnforceDomainWhitelist then return true end
    for _, domain in ipairs(Config.AllowedDomains or {}) do
        local cleanDomain = tostring(domain):lower():gsub("^www%.", ""):gsub("%.$", "")
        if host == cleanDomain or host:sub(-(#cleanDomain + 1)) == "." .. cleanDomain then return true end
    end
    return false
end

local function validateSubmission(url, hours, seconds)
    local cleanUrl = sanitizeImageUrl(url)
    if cleanUrl == "" or #cleanUrl > (Config.MaxUrlLength or 300) then
        return false, "The image URL is invalid or too long."
    end
    if cleanUrl:find("[%c%s]") then return false, "The image URL contains invalid characters." end
    local host = extractHost(cleanUrl)
    if not host or isPrivateHost(host) then return false, "Use a public HTTPS image URL." end
    if not hasValidImageExtension(cleanUrl) then return false, "The URL must point directly to a .png, .jpg, or .jpeg image." end
    if not isDomainAllowed(host) then return false, "This image host is not on the allowlist. Add it to AllowedDomains in config.lua if trusted." end
    local rawHours, rawSeconds = tonumber(hours), tonumber(seconds)
    if not rawHours or rawHours ~= rawHours or rawHours == math.huge or rawHours == -math.huge then return false, "The campaign duration is invalid." end
    if not rawSeconds or rawSeconds ~= rawSeconds or rawSeconds == math.huge or rawSeconds == -math.huge then return false, "The display duration is invalid." end
    local h = math.floor(rawHours)
    if h < Config.MinHours or h > Config.MaxHours then
        return false, string.format("Campaign hours must be between %d and %d.", Config.MinHours, Config.MaxHours)
    end
    local s = math.floor(rawSeconds)
    if s < Config.MinDisplaySeconds or s > Config.MaxDisplaySeconds then
        return false, string.format("Display seconds must be between %d and %d.", Config.MinDisplaySeconds, Config.MaxDisplaySeconds)
    end
    return true, cleanUrl, h, s
end

local function initDatabase()
    if dbConn and isElement(dbConn) then return true end
    dbConn = dbConnect("sqlite", "data.db")
    if not dbConn then
        outputDebugString("[Billboard-Ads] Failed to connect to SQLite database!", 1)
        return false
    end

    dbExec(dbConn, [[
        CREATE TABLE IF NOT EXISTS billboards (
            id INTEGER PRIMARY KEY,
            x REAL NOT NULL,
            y REAL NOT NULL,
            z REAL NOT NULL,
            rx REAL NOT NULL DEFAULT 0,
            ry REAL NOT NULL DEFAULT 0,
            rz REAL NOT NULL DEFAULT 0,
            interior INTEGER NOT NULL DEFAULT 0,
            dimension INTEGER NOT NULL DEFAULT 0
        )
    ]])

    local function ensureBillboardColumn(columnName, definition)
        local qh = dbQuery(dbConn, "PRAGMA table_info(billboards)")
        local columns = qh and (dbPoll(qh, -1) or {}) or {}
        for _, column in ipairs(columns) do
            if column.name == columnName then return true end
        end
        return dbExec(dbConn, "ALTER TABLE billboards ADD COLUMN " .. columnName .. " " .. definition)
    end
    if not ensureBillboardColumn("interior", "INTEGER NOT NULL DEFAULT 0") or not ensureBillboardColumn("dimension", "INTEGER NOT NULL DEFAULT 0") then
        outputDebugString("[Billboard-Ads] Failed to migrate billboard placement columns.", 1)
        return false
    end

    dbExec(dbConn, [[
        CREATE TABLE IF NOT EXISTS advertisements (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            imageUrl TEXT NOT NULL,
            displaySeconds INTEGER NOT NULL,
            ownerId TEXT NOT NULL,
            ownerName TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            endAt INTEGER NOT NULL DEFAULT 0,
            status INTEGER NOT NULL DEFAULT 2,
            remainingSeconds INTEGER NOT NULL DEFAULT 0
        )
    ]])

    dbExec(dbConn, "CREATE INDEX IF NOT EXISTS idx_ads_status ON advertisements (status)")
    dbExec(dbConn, "CREATE INDEX IF NOT EXISTS idx_ads_endAt ON advertisements (endAt)")
    return true
end

local function dbQueryRows(query, ...)
    if not dbConn then return {} end
    local qh = dbQuery(dbConn, query, ...)
    if not qh then return {} end
    return dbPoll(qh, -1) or {}
end

local function dbExecSafe(query, ...)
    if not dbConn then return false end
    return dbExec(dbConn, query, ...)
end

local function spawnRegistryPed()
    if isElement(adsPed) then destroyElement(adsPed) end
    if not Config.Ped or not Config.Ped.Enabled then return end

    local p = Config.Ped
    adsPed = createPed(p.Model or 17, p.X, p.Y, p.Z, p.RZ or 0)
    if isElement(adsPed) then
        setElementInterior(adsPed, p.Interior or 0)
        setElementDimension(adsPed, p.Dimension or 0)
        setElementFrozen(adsPed, true)
        setElementData(adsPed, "BillboardAds:Ped", true, true)
        if p.AnimationBlock and p.AnimationName then
            setPedAnimation(adsPed, p.AnimationBlock, p.AnimationName, -1, true, false, false, true)
        end
    end
end

local function loadBillboards()
    for _, data in pairs(billboards) do
        if isElement(data.object) then destroyElement(data.object) end
    end
    billboards = {}

    local rows = dbQueryRows("SELECT id, x, y, z, rx, ry, rz, interior, dimension FROM billboards ORDER BY id ASC")
    for _, row in ipairs(rows) do
        local id = tonumber(row.id)
        if id then
            local obj = createObject(Config.BillboardModel or 1916, row.x, row.y, row.z, row.rx, row.ry, row.rz)
            if isElement(obj) then
                setElementInterior(obj, tonumber(row.interior) or 0)
                setElementDimension(obj, tonumber(row.dimension) or 0)
                setElementFrozen(obj, true)
                billboards[id] = { id = id, object = obj }
            end
        end
    end
end

local function getReadyPlayers()
    local list = {}
    for player in pairs(readyPlayers) do
        if isElement(player) then
            list[#list + 1] = player
        else
            readyPlayers[player] = nil
        end
    end
    return list
end

local function getBillboardsSyncTable()
    local list = {}
    for _, data in pairs(billboards) do
        if isElement(data.object) then
            local x, y, z = getElementPosition(data.object)
            local _, _, rz = getElementRotation(data.object)
            list[#list + 1] = {
                id = data.id,
                element = data.object,
                x = math.floor(x * 100) / 100,
                y = math.floor(y * 100) / 100,
                z = math.floor(z * 100) / 100,
                rz = math.floor(rz * 10) / 10,
                interior = getElementInterior(data.object),
                dimension = getElementDimension(data.object)
            }
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

local function getBillboardsCleanList()
    local list = {}
    for _, data in pairs(billboards) do
        if isElement(data.object) then
            local x, y, z = getElementPosition(data.object)
            local _, _, rz = getElementRotation(data.object)
            list[#list + 1] = {
                id = data.id,
                x = math.floor(x * 100) / 100,
                y = math.floor(y * 100) / 100,
                z = math.floor(z * 100) / 100,
                rz = math.floor(rz * 10) / 10,
                interior = getElementInterior(data.object),
                dimension = getElementDimension(data.object)
            }
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

local function getAdsSyncList()
    local list = {}
    for _, ad in ipairs(ads) do
        list[#list + 1] = { id = ad.id, duration = ad.duration, hash = ad.imageHash, ext = ad.imageExt }
    end
    return list
end

local function sendAdImageToPlayer(player, ad)
    if not isElement(player) or not ad or not ad.ready or not ad.imageData then return end
    playerAdCache[player] = playerAdCache[player] or {}
    if playerAdCache[player][ad.id] == ad.imageHash then return end

    local bw = math.max(50000, math.min(250000, tonumber(Config.LatentBandwidth) or 120000))
    triggerLatentClientEvent(player, "BillboardAds:CacheImage", bw, false, resourceRoot, ad.id, ad.imageHash, ad.imageExt, ad.imageData)
    playerAdCache[player][ad.id] = ad.imageHash
end

local function broadcastAdImage(ad)
    for _, player in ipairs(getReadyPlayers()) do
        sendAdImageToPlayer(player, ad)
    end
end

local function broadcastRemoveImage(adId)
    local targets = getReadyPlayers()
    if #targets == 0 then return end
    triggerClientEvent(targets, "BillboardAds:RemoveImage", resourceRoot, adId)
    for _, player in ipairs(targets) do
        if playerAdCache[player] then playerAdCache[player][adId] = nil end
    end
end

local function syncAllPlayers()
    local targets = getReadyPlayers()
    if #targets == 0 then return end
    triggerClientEvent(targets, "BillboardAds:SyncAll", resourceRoot, getBillboardsSyncTable(), getAdsSyncList(), currentAdIndex)
end

local function broadcastActiveAd()
    if #ads == 0 then return end
    local ad = ads[currentAdIndex]
    if not ad then return end
    local targets = getReadyPlayers()
    if #targets == 0 then return end
    for _, player in ipairs(targets) do
        sendAdImageToPlayer(player, ad)
    end
    triggerClientEvent(targets, "BillboardAds:SetActiveAd", resourceRoot, currentAdIndex)
end

local function scheduleNextRotation()
    if isTimer(rotationTimer) then killTimer(rotationTimer) end
    rotationTimer = nil
    if #ads == 0 then return end

    local duration = math.max(1, tonumber(ads[currentAdIndex].duration) or Config.DefaultAdDuration or 10)
    rotationTimer = setTimer(function()
        if #ads == 0 then return end
        currentAdIndex = (currentAdIndex % #ads) + 1
        broadcastActiveAd()
        scheduleNextRotation()
    end, duration * 1000, 1)
end

local function rebuildReadyAds()
    local newAds, newById = {}, {}
    for _, ad in ipairs(adsAll) do
        if ad.ready then
            newAds[#newAds + 1] = ad
            newById[ad.id] = ad
        end
    end
    for id in pairs(adsById) do
        if not newById[id] then broadcastRemoveImage(id) end
    end
    ads = newAds
    adsById = newById

    if #ads == 0 then
        if isTimer(rotationTimer) then killTimer(rotationTimer) end
        rotationTimer = nil
        currentAdIndex = 1
        syncAllPlayers()
        return
    end

    if currentAdIndex > #ads then currentAdIndex = 1 end
    syncAllPlayers()
    broadcastActiveAd()
    scheduleNextRotation()
end

local function isAdStillActiveInDB(adId)
    local rows = dbQueryRows("SELECT status, endAt FROM advertisements WHERE id = ? LIMIT 1", adId)
    if #rows == 0 then return false end
    return tonumber(rows[1].status) == STATUS_ACTIVE and (tonumber(rows[1].endAt) or 0) > getNow()
end

local function fetchAdImage(ad)
    if not ad or not ad.id then return end

    local cached = adImageCache[ad.id]
    if cached then
        ad.ready = true
        ad.imageData = cached.data
        ad.imageHash = cached.hash
        ad.imageExt = cached.ext
        return
    end

    if ad.fetching then return end
    ad.fetching = true
    ad.fetchAttempts = (ad.fetchAttempts or 0) + 1

    local maxBytes = tonumber(Config.MaxImageBytes) or (2 * 1024 * 1024)
    local responseTooLarge = false
    local stopResponseGuard
    local okCall = fetchRemote(ad.url, {
        queueName = "billboard_ads",
        connectionAttempts = 2,
        connectTimeout = 8000,
        maxRedirects = 0,
        headers = HTTP_HEADERS
    }, function(response, info)
        if stopResponseGuard then responseTooLarge = stopResponseGuard() or responseTooLarge end
        ad.fetching = false
        if not isAdStillActiveInDB(ad.id) then
            rebuildReadyAds()
            return
        end

        local detectedExt = (not responseTooLarge and info and info.success and type(response) == "string" and #response <= maxBytes) and detectImageFormat(response) or nil

        if detectedExt then
            ad.imageData = response
            ad.imageHash = md5(response)
            ad.imageExt = detectedExt
            ad.ready = true
            ad.fetchAttempts = 0
            adImageCache[ad.id] = { data = response, hash = ad.imageHash, ext = detectedExt }
            cachePreview(ad.url, toDataUri(response, detectedExt))
            broadcastAdImage(ad)
            rebuildReadyAds()
        else
            if responseTooLarge then
                outputDebugString("[Billboard-Ads] Image response exceeded the configured size limit for Ad #" .. tostring(ad.id) .. ".", 2)
                rebuildReadyAds()
            else
                outputDebugString("[Billboard-Ads] Could not fetch a valid image for Ad #" .. tostring(ad.id) .. ".", 2)
                if ad.fetchAttempts < (Config.FetchMaxRetries or 3) then
                    setTimer(function()
                        if isAdStillActiveInDB(ad.id) and not ad.ready then
                            fetchAdImage(ad)
                        end
                    end, Config.FetchRetryDelayMs or 8000, 1)
                else
                    rebuildReadyAds()
                end
            end
        end
    end)

    if not okCall then
        ad.fetching = false
        outputDebugString("[Billboard-Ads] ERROR: fetchRemote blocked! Grant 'function.fetchRemote' in ACL.xml to this resource!", 1)
    else
        stopResponseGuard = watchRemoteResponseSize(okCall, maxBytes, function() responseTooLarge = true end)
    end
end

local function cleanupExpiredAds()
    local now = getNow()
    local expired = dbQueryRows(
        "SELECT id FROM advertisements WHERE (status = 1 AND endAt <= ?) OR (status = 0 AND remainingSeconds <= 0 AND endAt <= ?)",
        now, now
    )
    for _, row in ipairs(expired) do
        local id = tonumber(row.id)
        if id then adImageCache[id] = nil end
    end
    dbExecSafe(
        "DELETE FROM advertisements WHERE (status = 1 AND endAt <= ?) OR (status = 0 AND remainingSeconds <= 0 AND endAt <= ?)",
        now, now
    )
end

local function loadActiveAds()
    local now = getNow()
    local rows = dbQueryRows("SELECT id, imageUrl, displaySeconds FROM advertisements WHERE status = 1 AND endAt > ? ORDER BY id ASC", now)
    local existingById = {}
    for _, ad in ipairs(adsAll) do existingById[ad.id] = ad end
    local newAds = {}
    for _, row in ipairs(rows) do
        local id = tonumber(row.id)
        local url = sanitizeImageUrl(row.imageUrl)
        local host = extractHost(url)
        if id and url ~= "" and host and isDomainAllowed(host) and hasValidImageExtension(url) then
            local ad = existingById[id]
            if not ad or ad.url ~= url then
                ad = { id = id, url = url, duration = 10, ready = false, fetching = false, fetchAttempts = 0 }
            end
            ad.duration = math.max(1, tonumber(row.displaySeconds) or Config.DefaultAdDuration or 10)
            newAds[#newAds + 1] = ad
        else
            outputDebugString("[Billboard-Ads] Skipped an active ad with an invalid or non-allowlisted image URL.", 2)
        end
    end
    adsAll = newAds
    for _, ad in ipairs(adsAll) do
        if ad.ready and ad.imageData then
            adImageCache[ad.id] = adImageCache[ad.id] or { data = ad.imageData, hash = ad.imageHash, ext = ad.imageExt }
        else
            fetchAdImage(ad)
        end
    end
    rebuildReadyAds()
end

local function sendAdminDataToPlayer(player)
    if not isElement(player) then return end
    local now = getNow()
    local rows = dbQueryRows("SELECT id, imageUrl, displaySeconds, ownerName, endAt, status, remainingSeconds FROM advertisements ORDER BY status DESC, id DESC LIMIT 100")
    local list = {}
    for _, row in ipairs(rows) do
        local st = tonumber(row.status)
        local endAt = tonumber(row.endAt) or 0
        local rem = tonumber(row.remainingSeconds) or 0
        local statusStr = "inactive"
        if st == STATUS_REJECTED then statusStr = "rejected"
        elseif st == STATUS_PENDING then statusStr = "pending"
        elseif st == STATUS_ACTIVE and endAt > now then statusStr = "active"
        elseif st == STATUS_INACTIVE and rem > 0 then statusStr = "paused" end

        list[#list + 1] = {
            id = tonumber(row.id),
            imageUrl = tostring(row.imageUrl or ""),
            displaySeconds = tonumber(row.displaySeconds) or 10,
            ownerAccount = tostring(row.ownerName or "Unknown"),
            endAt = endAt,
            status = statusStr,
            remainingSeconds = rem
        }
    end
    triggerClientEvent(player, "BillboardAds:ReceiveAdminList", resourceRoot, list, now, getBillboardsCleanList(), hasModeratorPermission(player), hasBuilderPermission(player))
end

local function sendPreviewResult(player, success, payload, targetView, requestId)
    if not isElement(player) then return end
    local view = targetView == "admin" and "admin" or "submit"
    local token = tonumber(requestId) or 0
    local latest = latestPreviewRequest[player]
    if latest and latest[view] ~= token then return end

    payload = payload or ""
    if success and type(payload) == "string" and #payload > 32768 then
        local sent = triggerLatentClientEvent(
            player,
            "BillboardAds:PreviewResult",
            tonumber(Config.PreviewBandwidth) or 512000,
            false,
            resourceRoot,
            true,
            payload,
            view,
            token
        )
        if not sent then
            triggerClientEvent(player, "BillboardAds:PreviewResult", resourceRoot, false, "The preview could not be transferred. Try a smaller image.", view, token)
        end
        return
    end
    triggerClientEvent(player, "BillboardAds:PreviewResult", resourceRoot, success, payload, view, token)
end

local startPreviewFetch

local function countQueuedPreviewRequests()
    local count = 0
    for player in pairs(previewQueued) do
        if isElement(player) then count = count + 1 else previewQueued[player] = nil end
    end
    return count
end

local function queuePreviewRequest(player, request)
    if previewQueued[player] then
        previewQueued[player] = request
        return true
    end
    if countQueuedPreviewRequests() >= PREVIEW_QUEUE_LIMIT then return false end
    previewQueued[player] = request
    return true
end

local function pumpPreviewQueue()
    if previewFetchActive >= PREVIEW_FETCH_LIMIT then return end
    for player, request in pairs(previewQueued) do
        if not isElement(player) then
            previewQueued[player] = nil
        elseif not previewInFlight[player] then
            previewQueued[player] = nil
            local cached = getCachedPreview(request.url)
            if cached then
                sendPreviewResult(player, true, cached, request.targetView, request.requestId)
            else
                startPreviewFetch(player, request.url, request.targetView, request.requestId)
            end
            if previewFetchActive >= PREVIEW_FETCH_LIMIT then return end
        end
    end
end

startPreviewFetch = function(player, cleanUrl, targetView, requestId)
    if not isElement(player) then return end
    if previewInFlight[player] or previewFetchActive >= PREVIEW_FETCH_LIMIT then
        if not queuePreviewRequest(player, { url = cleanUrl, targetView = targetView, requestId = requestId }) then
            sendPreviewResult(player, false, "The preview service is busy. Try again shortly.", targetView, requestId)
        end
        return
    end

    previewInFlight[player] = true
    previewFetchActive = previewFetchActive + 1
    local finished = false
    local function releaseFetchSlot()
        if finished then return end
        finished = true
        previewFetchActive = math.max(0, previewFetchActive - 1)
        previewInFlight[player] = nil
    end

    local queueName = "billboard_preview_" .. md5(tostring(getPlayerSerial(player) or "unknown"))
    local maxBytes = tonumber(Config.MaxImageBytes) or (2 * 1024 * 1024)
    local responseTooLarge = false
    local stopResponseGuard
    local okCall = fetchRemote(cleanUrl, {
        queueName = queueName,
        connectionAttempts = 1,
        connectTimeout = 6000,
        maxRedirects = 0,
        headers = HTTP_HEADERS
    }, function(response, info)
        if stopResponseGuard then responseTooLarge = stopResponseGuard() or responseTooLarge end
        releaseFetchSlot()
        if isElement(player) then
            local ext = (not responseTooLarge and info and info.success and type(response) == "string" and #response <= maxBytes) and detectImageFormat(response) or nil
            if ext then
                local dataUri = toDataUri(response, ext)
                cachePreview(cleanUrl, dataUri)
                sendPreviewResult(player, true, dataUri, targetView, requestId)
            else
                local reason = responseTooLarge and "The image response exceeded the configured byte limit." or "The URL did not return a supported PNG or JPEG image within the configured size and dimension limits."
                sendPreviewResult(player, false, reason, targetView, requestId)
            end
        end
        pumpPreviewQueue()
    end)
    if not okCall then
        releaseFetchSlot()
        if isElement(player) then
            sendPreviewResult(player, false, "The server cannot fetch images. Grant function.fetchRemote to this resource in ACL.", targetView, requestId)
        end
        pumpPreviewQueue()
    else
        stopResponseGuard = watchRemoteResponseSize(okCall, maxBytes, function() responseTooLarge = true end)
    end
end
addEvent("BillboardAds:RequestPreview", true)
addEventHandler("BillboardAds:RequestPreview", resourceRoot, function(rawUrl, targetView, requestId)
    local player = client
    if not isElement(player) or source ~= resourceRoot then return end
    if isRateLimited("preview", player, 400) then return end
    local view = targetView == "admin" and "admin" or "submit"
    local numericToken = tonumber(requestId) or 0
    if numericToken ~= numericToken or numericToken == math.huge or numericToken == -math.huge then numericToken = 0 end
    local token = math.max(0, math.min(2147483647, math.floor(numericToken)))
    latestPreviewRequest[player] = latestPreviewRequest[player] or {}
    latestPreviewRequest[player][view] = token
    local cleanUrl = sanitizeImageUrl(rawUrl)
    local host = extractHost(cleanUrl)
    if cleanUrl == "" or not host or isPrivateHost(host) or not isDomainAllowed(host) or not hasValidImageExtension(cleanUrl) then
        sendPreviewResult(player, false, "Use a direct PNG or JPEG image URL from a trusted, allowlisted public host.", view, token)
        return
    end
    local cached = getCachedPreview(cleanUrl)
    if cached then
        sendPreviewResult(player, true, cached, view, token)
        return
    end
    startPreviewFetch(player, cleanUrl, view, token)
end)

addEvent("BillboardAds:ClientReady", true)
addEventHandler("BillboardAds:ClientReady", resourceRoot, function()
    if not client or source ~= resourceRoot then return end
    if isRateLimited("sync", client, SYNC_COOLDOWN) then return end
    readyPlayers[client] = true
    triggerClientEvent(client, "BillboardAds:SyncAll", resourceRoot, getBillboardsSyncTable(), getAdsSyncList(), currentAdIndex)
    for _, ad in ipairs(ads) do
        sendAdImageToPlayer(client, ad)
    end
end)

addEvent("BillboardAds:InteractPed", true)
addEventHandler("BillboardAds:InteractPed", resourceRoot, function()
    if not client or source ~= resourceRoot or isRateLimited("interact", client, 500) or not isNearAdsPed(client) then return end
    local isMod = hasModeratorPermission(client)
    local isBuilder = hasBuilderPermission(client)
    triggerClientEvent(client, "BillboardAds:OpenUI", resourceRoot, "submit", isMod, isBuilder)
    if isMod then sendAdminDataToPlayer(client) end
end)

addEvent("BillboardAds:RequestAdminList", true)
addEventHandler("BillboardAds:RequestAdminList", resourceRoot, function()
    if not client or source ~= resourceRoot or not hasModeratorPermission(client) then return end
    if isRateLimited("adminList", client, 300) then return end
    sendAdminDataToPlayer(client)
end)

addEvent("BillboardAds:SubmitAd", true)
addEventHandler("BillboardAds:SubmitAd", resourceRoot, function(url, hours, seconds)
    local player = client
    if not isElement(player) or source ~= resourceRoot or isPedDead(player) then return end
    if isRateLimited("submit", player, ACTION_COOLDOWN) or submitPending[player] then return end
    if not isNearAdsPed(player) then
        triggerClientEvent(player, "BillboardAds:SubmitResult", resourceRoot, false, "Move closer to the advertising clerk.")
        return
    end

    local ok, validUrl, validHours, validSeconds = validateSubmission(url, hours, seconds)
    if not ok then
        triggerClientEvent(player, "BillboardAds:SubmitResult", resourceRoot, false, validUrl)
        return
    end

    local ownerId = getPlayerIdentifier(player)
    local ownerName = getPlayerDisplayName(player)
    local now = getNow()

    local activeRows = dbQueryRows(
        "SELECT COUNT(*) AS cnt FROM advertisements WHERE ownerId = ? AND (status = 2 OR (status = 1 AND endAt > ?))",
        ownerId, now
    )
    local activeCount = activeRows[1] and tonumber(activeRows[1].cnt) or 0
    if activeCount >= (Config.MaxConcurrentAdsPerPlayer or 3) and not hasModeratorPermission(player) then
        triggerClientEvent(player, "BillboardAds:SubmitResult", resourceRoot, false, "You have reached the active campaign limit.")
        return
    end

    local price = math.max(0, math.floor(validHours * validSeconds * (Config.PricePerHourPerSecond or 500)))
    if not Config.Money.Has(player, price) then
        triggerClientEvent(player, "BillboardAds:SubmitResult", resourceRoot, false, "You do not have enough money for this campaign.", price)
        return
    end

    submitPending[player] = true
    if not Config.Money.Take(player, price) then
        submitPending[player] = nil
        triggerClientEvent(player, "BillboardAds:SubmitResult", resourceRoot, false, "Could not charge the campaign cost.", price)
        return
    end

    local totalSeconds = validHours * 3600
    local inserted = dbExecSafe(
        "INSERT INTO advertisements (imageUrl, displaySeconds, ownerId, ownerName, createdAt, endAt, status, remainingSeconds) VALUES (?, ?, ?, ?, ?, 0, 2, ?)",
        validUrl, validSeconds, ownerId, ownerName, now, totalSeconds
    )

    submitPending[player] = nil
    if not inserted then
        Config.Money.Give(player, price)
        triggerClientEvent(player, "BillboardAds:SubmitResult", resourceRoot, false, "A database error occurred.", price)
        return
    end

    triggerClientEvent(player, "BillboardAds:SubmitResult", resourceRoot, true, "Your advertisement was submitted for review.", price)
    if hasModeratorPermission(player) then sendAdminDataToPlayer(player) end
end)

addEvent("BillboardAds:AdminAction", true)
addEventHandler("BillboardAds:AdminAction", resourceRoot, function(action, adId)
    local player = client
    if not isElement(player) or source ~= resourceRoot or not hasModeratorPermission(player) then return end
    if isRateLimited("adminAction", player, ACTION_COOLDOWN) then return end

    local id = tonumber(adId)
    if not id then return end

    local rows = dbQueryRows("SELECT * FROM advertisements WHERE id = ? LIMIT 1", id)
    if #rows == 0 then
        triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "The advertisement was not found.")
        return
    end

    local ad = rows[1]
    local st = tonumber(ad.status)
    local now = getNow()

    if action == "accept" then
        if st ~= STATUS_PENDING then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "The advertisement is not pending review.")
            return
        end
        local activeRows = dbQueryRows("SELECT COUNT(*) AS cnt FROM advertisements WHERE status = 1 AND endAt > ?", now)
        local activeCount = activeRows[1] and tonumber(activeRows[1].cnt) or 0
        if activeCount >= (tonumber(Config.MaxActiveAds) or 50) then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "The active-ad limit has been reached.")
            return
        end
        local rem = tonumber(ad.remainingSeconds) or 0
        if rem <= 0 then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "The campaign has no time remaining.")
            return
        end
        if not dbExecSafe("UPDATE advertisements SET status = 1, endAt = ?, remainingSeconds = 0 WHERE id = ?", now + rem, id) then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "Failed to update the campaign in the database.")
            return
        end
        triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, true, "Advertisement #" .. id .. " was approved and published.")

    elseif action == "reject" then
        if st ~= STATUS_PENDING then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "The advertisement is not pending review.")
            return
        end
        if not dbExecSafe("UPDATE advertisements SET status = 3, remainingSeconds = 0 WHERE id = ?", id) then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "Failed to reject the campaign in the database.")
            return
        end
        adImageCache[id] = nil
        triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, true, "Ad #" .. id .. " was rejected.")

    elseif action == "pause" then
        if st ~= STATUS_ACTIVE then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "The advertisement is not active.")
            return
        end
        local rem = math.max(0, (tonumber(ad.endAt) or 0) - now)
        if not dbExecSafe("UPDATE advertisements SET status = 0, remainingSeconds = ? WHERE id = ?", rem, id) then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "Failed to pause the campaign in the database.")
            return
        end
        adImageCache[id] = nil
        triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, true, "Ad #" .. id .. " was paused.")

    elseif action == "resume" then
        if st ~= STATUS_INACTIVE then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "The advertisement is not paused.")
            return
        end
        local rem = tonumber(ad.remainingSeconds) or 0
        if rem <= 0 then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "This advertisement has no time remaining.")
            return
        end
        local activeRows = dbQueryRows("SELECT COUNT(*) AS cnt FROM advertisements WHERE status = 1 AND endAt > ?", now)
        local activeCount = activeRows[1] and tonumber(activeRows[1].cnt) or 0
        if activeCount >= (tonumber(Config.MaxActiveAds) or 50) then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "The active-ad limit has been reached.")
            return
        end
        if not dbExecSafe("UPDATE advertisements SET status = 1, endAt = ?, remainingSeconds = 0 WHERE id = ?", now + rem, id) then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "Failed to update the campaign in the database.")
            return
        end
        triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, true, "Ad #" .. id .. " was resumed.")

    elseif action == "delete" then
        if not dbExecSafe("DELETE FROM advertisements WHERE id = ?", id) then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "Failed to delete the campaign from the database.")
            return
        end
        adImageCache[id] = nil
        triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, true, "Ad #" .. id .. " was deleted.")
    end

    cleanupExpiredAds()
    loadActiveAds()
    sendAdminDataToPlayer(player)
end)

addEvent("BillboardAds:BillboardAction", true)
addEventHandler("BillboardAds:BillboardAction", resourceRoot, function(action, billboardId, value, x, y, z, rz, interior, dimension)
    local player = client
    if not isElement(player) or source ~= resourceRoot or not hasBuilderPermission(player) then
        if isElement(player) then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "You do not have permission to manage billboards.")
        end
        return
    end
    if isRateLimited("billboardAction", player, 400) then return end

    if action == "getposition" then
        local px, py, pz = getElementPosition(player)
        local _, _, playerRz = getElementRotation(player)
        triggerClientEvent(player, "BillboardAds:PlacementValues", resourceRoot, px, py, pz + 5.4, playerRz, getElementInterior(player), getElementDimension(player))
        return
    end

    if action == "create" or action == "createhere" then
        local billboardCount = 0
        for _ in pairs(billboards) do billboardCount = billboardCount + 1 end
        if billboardCount >= (tonumber(Config.MaxBillboards) or 250) then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "The billboard limit has been reached.")
            return
        end

        if action == "createhere" or x == nil or y == nil or z == nil then
            x, y, z = getElementPosition(player)
            z = z + 5.4
            local _, _, playerRz = getElementRotation(player)
            rz = playerRz
            interior = getElementInterior(player)
            dimension = getElementDimension(player)
        end
        local valid, px, py, pz, pr, pint, pdim = validateBillboardPlacement(x, y, z, rz, interior, dimension)
        if not valid then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, px)
            return
        end

        local rows = dbQueryRows("SELECT COALESCE(MAX(id), 0) + 1 AS nextId FROM billboards")
        local newId = rows[1] and tonumber(rows[1].nextId) or 1
        local inserted = dbExecSafe(
            "INSERT INTO billboards (id, x, y, z, rx, ry, rz, interior, dimension) VALUES (?, ?, ?, ?, 0, 0, ?, ?, ?)",
            newId, px, py, pz, pr, pint, pdim
        )
        if not inserted then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "Failed to save the new billboard.")
            return
        end

        local obj = createObject(Config.BillboardModel or 1916, px, py, pz, 0, 0, pr)
        if not isElement(obj) then
            dbExecSafe("DELETE FROM billboards WHERE id = ?", newId)
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "Could not create the billboard object.")
            return
        end
        setElementInterior(obj, pint)
        setElementDimension(obj, pdim)
        setElementFrozen(obj, true)
        billboards[newId] = { id = newId, object = obj }
        syncAllPlayers()
        sendAdminDataToPlayer(player)
        triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, true, "Created billboard #" .. newId .. ".")
        return
    end

    local bId = tonumber(billboardId)
    local data = bId and billboards[bId]
    if not data or not isElement(data.object) then
        triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "The selected billboard was not found.")
        return
    end

    if action == "teleport" then
        local bx, by, bz = getElementPosition(data.object)
        setElementInterior(player, getElementInterior(data.object))
        setElementDimension(player, getElementDimension(data.object))
        setElementPosition(player, bx + 3.0, by + 3.0, bz - 4.0)
        triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, true, "Teleported to billboard #" .. bId .. ".")

    elseif action == "movehere" then
        local px, py, pz = getElementPosition(player)
        pz = pz + 5.4
        local pint, pdim = getElementInterior(player), getElementDimension(player)
        if not dbExecSafe("UPDATE billboards SET x = ?, y = ?, z = ?, interior = ?, dimension = ? WHERE id = ?", px, py, pz, pint, pdim, bId) then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "Failed to update the billboard in the database.")
            return
        end
        setElementPosition(data.object, px, py, pz)
        setElementInterior(data.object, pint)
        setElementDimension(data.object, pdim)
        setElementFrozen(data.object, true)
        syncAllPlayers()
        sendAdminDataToPlayer(player)
        triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, true, "Moved billboard #" .. bId .. " to your position.")

    elseif action == "setposition" then
        local valid, px, py, pz, pr, pint, pdim = validateBillboardPlacement(x, y, z, rz, interior, dimension)
        if not valid then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, px)
            return
        end
        if not dbExecSafe("UPDATE billboards SET x = ?, y = ?, z = ?, rz = ?, interior = ?, dimension = ? WHERE id = ?", px, py, pz, pr, pint, pdim, bId) then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "Failed to update the billboard in the database.")
            return
        end
        setElementPosition(data.object, px, py, pz)
        setElementRotation(data.object, 0, 0, pr)
        setElementInterior(data.object, pint)
        setElementDimension(data.object, pdim)
        setElementFrozen(data.object, true)
        syncAllPlayers()
        sendAdminDataToPlayer(player)
        triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, true, "Updated placement for billboard #" .. bId .. ".")

    elseif action == "rotate" then
        local newRz = finiteNumber(value)
        if not newRz or newRz < 0 or newRz > 360 then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "Rotation must be between 0 and 360 degrees.")
            return
        end
        newRz = newRz % 360
        if not dbExecSafe("UPDATE billboards SET rz = ? WHERE id = ?", newRz, bId) then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "Failed to update the billboard in the database.")
            return
        end
        setElementRotation(data.object, 0, 0, newRz)
        syncAllPlayers()
        sendAdminDataToPlayer(player)
        triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, true, "Updated rotation for billboard #" .. bId .. ".")

    elseif action == "delete" then
        if not dbExecSafe("DELETE FROM billboards WHERE id = ?", bId) then
            triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, false, "Failed to delete the billboard from the database.")
            return
        end
        destroyElement(data.object)
        billboards[bId] = nil
        syncAllPlayers()
        sendAdminDataToPlayer(player)
        triggerClientEvent(player, "BillboardAds:AdminResult", resourceRoot, true, "Deleted billboard #" .. bId .. ".")
    end
end)

local function openBillboardsAdminPanel(player)
    if not isElement(player) or getElementType(player) ~= "player" then return end
    if not hasBuilderPermission(player) then
        outputChatBox("[Billboard Ads] You do not have permission to manage billboards.", player, 255, 90, 90)
        return
    end
    if isRateLimited("interact", player, 750) then return end
    triggerClientEvent(player, "BillboardAds:OpenUI", resourceRoot, "billboards", hasModeratorPermission(player), true)
end

local adminPanelCommand = tostring(Config.AdminPanelCommand or "billboards")
if not adminPanelCommand:match("^[%a][%w_]*$") then adminPanelCommand = "billboards" end
addCommandHandler(adminPanelCommand, openBillboardsAdminPanel, false, false)

addEventHandler("onPlayerQuit", root, function()
    readyPlayers[source] = nil
    playerAdCache[source] = nil
    submitPending[source] = nil
    rateLimits.sync[source] = nil
    rateLimits.submit[source] = nil
    rateLimits.adminList[source] = nil
    rateLimits.adminAction[source] = nil
    rateLimits.billboardAction[source] = nil
    rateLimits.preview[source] = nil
    rateLimits.interact[source] = nil
    previewInFlight[source] = nil
    previewQueued[source] = nil
    latestPreviewRequest[source] = nil
end)

addEventHandler("onResourceStart", resourceRoot, function()
    if not hasObjectPermissionTo(getThisResource(), "function.fetchRemote", false) then
        outputDebugString("[Billboard-Ads] WARNING: Resource does NOT have 'function.fetchRemote' permission in ACL.xml! Images will NOT load until granted.", 1)
    end
    if initDatabase() then
        spawnRegistryPed()
        loadBillboards()
        cleanupExpiredAds()
        loadActiveAds()
    end
end)

setTimer(function()
    cleanupExpiredAds()
    loadActiveAds()
end, 60000, 0)
