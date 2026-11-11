Config = Config or {}
Config.DefaultLanguage = Config.DefaultLanguage or "en"
Config.BillboardModel = Config.BillboardModel or 1916
Config.BillboardTextures = Config.BillboardTextures or { "000001858D3FC5B8", "000001858C7879B8" }
Config.StreamDistance = Config.StreamDistance or 150
Config.StreamIntervalMs = Config.StreamIntervalMs or 750
Config.FadeDurationMs = Config.FadeDurationMs or 1000
Config.MinHours = Config.MinHours or 1
Config.MaxHours = Config.MaxHours or 48
Config.MinDisplaySeconds = Config.MinDisplaySeconds or 5
Config.MaxDisplaySeconds = Config.MaxDisplaySeconds or 15
Config.DefaultAdDuration = Config.DefaultAdDuration or 10
Config.PricePerHourPerSecond = Config.PricePerHourPerSecond or 500
Config.DefaultUploadSite = Config.DefaultUploadSite or "https://imgbb.com/"
Config.AllowedDomains = Config.AllowedDomains or { "top4top.io", "i.imgur.com", "i.postimg.cc", "i.ibb.co" }
Config.Ped = Config.Ped or { InteractionDistance = 4.5, InteractionKey = "e" }

local billboards = {}
local ads = {}
local adsById = {}
local adAssets = {}
local fadeJobs = {}
local cachedFiles = {}
local pendingAssetCleanup = {}

local streamTimer = nil
local activeAdIndex = nil
local activeAdId = nil
local pendingActiveAdId = nil
local previousActiveAdId = nil
local renderingAdId = nil
local showBillboardIds3D = false

local CACHE_DIR = "assets/cache_"
local CACHE_MANIFEST = "assets/cache_index.txt"

local function loadBillboardModel()
    local model = Config.BillboardModel
    local txd = engineLoadTXD("assets/1916.txd", true)
    if txd then engineImportTXD(txd, model) end
    local dff = engineLoadDFF("assets/1916.dff", 0)
    if dff then engineReplaceModel(dff, model) end
    local col = engineLoadCOL("assets/1916.col")
    if col then engineReplaceCOL(col, model) end
    engineSetModelLODDistance(model, 300)
end

local function getCachePath(hash, ext)
    return CACHE_DIR .. tostring(hash) .. "." .. tostring(ext)
end

local function saveCacheManifest()
    local file = fileCreate(CACHE_MANIFEST)
    if not file then return end
    for path in pairs(cachedFiles) do
        fileWrite(file, path .. "\n")
    end
    fileClose(file)
end

local function cleanupCacheFiles()
    if fileExists(CACHE_MANIFEST) then
        local file = fileOpen(CACHE_MANIFEST)
        if file then
            local size = fileGetSize(file) or 0
            local content = size > 0 and fileRead(file, size) or ""
            fileClose(file)
            for line in content:gmatch("[^\r\n]+") do
                local hash, ext = line:match("^assets/cache_([%da-fA-F]+)%.([%a]+)$")
                if hash and #hash == 32 and (ext == "png" or ext == "jpg") and fileExists(line) then
                    fileDelete(line)
                end
            end
        end
        fileDelete(CACHE_MANIFEST)
    end
    cachedFiles = {}
end

local function writeCacheFile(path, data)
    local file = fileCreate(path)
    if not file then return false end
    local written = fileWrite(file, data)
    fileClose(file)
    if not written or written ~= #data then
        if fileExists(path) then fileDelete(path) end
        return false
    end
    cachedFiles[path] = true
    saveCacheManifest()
    return true
end

local function removeShaderFromBillboard(billboard)
    if not billboard or not billboard.shaderApplied then return end
    if isElement(billboard.appliedShader) and isElement(billboard.element) then
        for _, texName in ipairs(Config.BillboardTextures) do
            engineRemoveShaderFromWorldTexture(billboard.appliedShader, texName, billboard.element)
        end
    end
    billboard.shaderApplied = false
    billboard.appliedShader = nil
end

local function applyShaderToBillboard(billboard, shader)
    if not billboard or not isElement(shader) or not isElement(billboard.element) then return end
    if billboard.appliedShader == shader then return end
    if billboard.shaderApplied then removeShaderFromBillboard(billboard) end

    local applied = false
    for _, texName in ipairs(Config.BillboardTextures) do
        if engineApplyShaderToWorldTexture(shader, texName, billboard.element) then
            applied = true
        end
    end
    if applied then
        billboard.shaderApplied = true
        billboard.appliedShader = shader
    end
end

local function destroyAdAssets(adId, keepFile, force)
    local assets = adAssets[adId]
    if not assets then
        pendingAssetCleanup[adId] = nil
        return
    end
    if renderingAdId == adId and not force then
        pendingAssetCleanup[adId] = keepFile == true
        return
    end
    pendingAssetCleanup[adId] = nil
    for _, billboard in pairs(billboards) do
        if assets.shader and billboard.appliedShader == assets.shader then
            removeShaderFromBillboard(billboard)
        end
    end
    if assets.shader then
        fadeJobs[assets.shader] = nil
        if isElement(assets.shader) then destroyElement(assets.shader) end
    end
    if isElement(assets.texture) then destroyElement(assets.texture) end
    if not keepFile and assets.path and fileExists(assets.path) then
        fileDelete(assets.path)
        cachedFiles[assets.path] = nil
        saveCacheManifest()
    end
    adAssets[adId] = nil
end

local function createAssetsFromPath(adId, hash, ext, path)
    local texture = dxCreateTexture(path, "dxt5", true, "clamp")
    if not texture then return false end

    local shader = dxCreateShader("assets/shader.fx", 0, 0, false, "object")
    if not shader then
        destroyElement(texture)
        return false
    end

    dxSetShaderValue(shader, "gTextureA", texture)
    dxSetShaderValue(shader, "gTextureB", texture)
    dxSetShaderValue(shader, "gBlend", 1)
    dxSetShaderValue(shader, "gAlpha", 1)

    adAssets[adId] = { id = adId, hash = hash, ext = ext, path = path, texture = texture, shader = shader }
    return true
end

local function startShaderFade(shader, oldTexture)
    if not isElement(shader) then return end
    fadeJobs[shader] = { startTick = getTickCount(), duration = math.max(1, tonumber(Config.FadeDurationMs) or 1000) }
    dxSetShaderValue(shader, "gAlpha", 1)
    if isElement(oldTexture) then
        dxSetShaderValue(shader, "gTextureA", oldTexture)
        dxSetShaderValue(shader, "gBlend", 0)
    else
        dxSetShaderValue(shader, "gBlend", 1)
    end
end

local function setActiveAdId(adId)
    if not adId then
        for _, billboard in pairs(billboards) do
            removeShaderFromBillboard(billboard)
        end
        activeAdId = nil
        previousActiveAdId = nil
        renderingAdId = nil
        for shader in pairs(fadeJobs) do fadeJobs[shader] = nil end
        local cleanup = {}
        for id, keepFile in pairs(pendingAssetCleanup) do cleanup[#cleanup + 1] = { id = id, keepFile = keepFile } end
        for _, item in ipairs(cleanup) do destroyAdAssets(item.id, item.keepFile) end
        return
    end
    if activeAdId == adId then return end
    previousActiveAdId = activeAdId or renderingAdId
    activeAdId = adId

    local shader = activeAdId and adAssets[activeAdId] and adAssets[activeAdId].shader or nil
    local oldTex = previousActiveAdId and adAssets[previousActiveAdId] and adAssets[previousActiveAdId].texture or nil

    if shader then
        startShaderFade(shader, oldTex)
        for _, b in pairs(billboards) do
            if b.streamed then applyShaderToBillboard(b, shader) end
        end
    end
end

local function setActiveAdByIndex(index)
    local idx = tonumber(index) or 1
    if #ads == 0 then
        pendingActiveAdId, activeAdIndex = nil, nil
        setActiveAdId(nil)
        return
    end
    if idx < 1 or idx > #ads then idx = 1 end
    activeAdIndex = idx
    local entry = ads[idx]
    if not entry then return end

    if adAssets[entry.id] and isElement(adAssets[entry.id].shader) then
        pendingActiveAdId = nil
        setActiveAdId(entry.id)
    else
        pendingActiveAdId = entry.id
    end
end

local function streamTick()
    local px, py, pz = getElementPosition(localPlayer)
    local pDim, pInt = getElementDimension(localPlayer), getElementInterior(localPlayer)
    local maxDistSq = Config.StreamDistance ^ 2

    for _, b in pairs(billboards) do
        if isElement(b.element) then
            if getElementDimension(b.element) ~= pDim or getElementInterior(b.element) ~= pInt then
                if b.streamed then b.streamed = false; removeShaderFromBillboard(b) end
            else
                local bx, by, bz = getElementPosition(b.element)
                local distSq = (px - bx)^2 + (py - by)^2 + (pz - bz)^2
                if distSq <= maxDistSq then
                    if not b.streamed then
                        b.streamed = true
                        local activeShader = activeAdId and adAssets[activeAdId] and adAssets[activeAdId].shader
                        if activeShader then applyShaderToBillboard(b, activeShader) end
                    end
                elseif b.streamed then
                    b.streamed = false
                    removeShaderFromBillboard(b)
                end
            end
        end
    end
end

local adsGui, adsBrowser = nil, nil
local browserReady, isPanelOpen = false, false
local canAccessAdmin, canBuildBillboards = false, false
local initialTabMode = "submit"
local lastAdminList, lastBillboardsList, lastServerNow = {}, {}, 0
local savedLang = Config.DefaultLanguage

local function sanitizeBillboardsForJSON(rawList)
    local clean = {}
    for _, item in ipairs(rawList or {}) do
        if type(item) == "table" and tonumber(item.id) then
            clean[#clean + 1] = {
                id = tonumber(item.id),
                x = tonumber(item.x) or 0,
                y = tonumber(item.y) or 0,
                z = tonumber(item.z) or 0,
                rz = tonumber(item.rz) or 0,
                interior = tonumber(item.interior) or 0,
                dimension = tonumber(item.dimension) or 0
            }
        end
    end
    return clean
end

local function encodeJSArgument(value)
    local encoded = toJSON({ value = value }, true)
    if type(encoded) ~= "string" then return "null" end
    return encoded:match("^%[%{\"value\":(.*)%}%]$") or "null"
end

local function pushInitToBrowser(tabToOpen)
    if not isElement(adsBrowser) or not browserReady then return end
    local jsonStr = toJSON({
        settings = {
            minHours = Config.MinHours,
            maxHours = Config.MaxHours,
            minDisplaySeconds = Config.MinDisplaySeconds,
            maxDisplaySeconds = Config.MaxDisplaySeconds,
            defaultAdDuration = Config.DefaultAdDuration,
            pricePerHourPerSecond = Config.PricePerHourPerSecond,
            defaultUploadSite = Config.DefaultUploadSite,
            allowedDomains = Config.AllowedDomains,
        },
        isAdmin = canAccessAdmin,
        isBuilder = canBuildBillboards,
        show3DIds = showBillboardIds3D,
        mode = tabToOpen,
        lang = savedLang
    })
    if jsonStr then
        executeBrowserJavascript(adsBrowser, "initAdsPanel(" .. jsonStr:sub(2, -2) .. ");")
    end
end

local function pushAdminDataToBrowser()
    if not isElement(adsBrowser) or not browserReady then return end
    local jsonStr = toJSON({
        list = lastAdminList or {},
        billboards = sanitizeBillboardsForJSON(lastBillboardsList),
        serverNow = tonumber(lastServerNow) or 0,
        isAdmin = canAccessAdmin,
        isBuilder = canBuildBillboards
    })
    if jsonStr then
        executeBrowserJavascript(adsBrowser, "loadAdminAdsData(" .. jsonStr:sub(2, -2) .. ");")
    end
end

local function pushToast(statusType, message)
    if isElement(adsBrowser) and browserReady and isElement(adsGui) and guiGetVisible(adsGui) then
        local arguments = table.concat({
            encodeJSArgument(tostring(statusType or "info")),
            encodeJSArgument(tostring(message or ""))
        }, ",")
        executeBrowserJavascript(adsBrowser, "showStatusToast(" .. arguments .. ");")
    else
        outputChatBox("[Ads] " .. tostring(message), 61, 220, 132)
    end
end

local function openPanel(mode, isAdmin, isBuilder)
    initialTabMode = mode or "submit"
    if isAdmin ~= nil then canAccessAdmin = (isAdmin == true) end
    if isBuilder ~= nil then canBuildBillboards = (isBuilder == true) end

    if not isElement(adsGui) then
        local sw, sh = guiGetScreenSize()
        adsGui = guiCreateBrowser(0, 0, sw, sh, true, true, false)
        adsBrowser = guiGetBrowser(adsGui)
        addEventHandler("onClientBrowserCreated", adsGui, function()
            loadBrowserURL(adsBrowser, "http://mta/local/ui/index.html")
        end)
        addEventHandler("onClientBrowserDocumentReady", adsGui, function()
            browserReady = true
            pushInitToBrowser(initialTabMode)
            if canAccessAdmin then pushAdminDataToBrowser() end
        end)
    else
        pushInitToBrowser(initialTabMode)
        if canAccessAdmin then pushAdminDataToBrowser() end
    end

    guiSetVisible(adsGui, true)
    guiBringToFront(adsGui)
    guiSetInputMode("no_binds_when_editing")
    showCursor(true)
    if isElement(adsBrowser) then focusBrowser(adsBrowser) end
    isPanelOpen = true
end

local function closePanel()
    if isElement(adsGui) then guiSetVisible(adsGui, false) end
    showCursor(false)
    guiSetInputMode("allow_binds")
    isPanelOpen = false
end

addEvent("BillboardAds:SyncAll", true)
addEventHandler("BillboardAds:SyncAll", resourceRoot, function(entries, adsList, currentIndex)
    for _, b in pairs(billboards) do removeShaderFromBillboard(b) end
    billboards = {}
    lastBillboardsList = {}
    for _, entry in ipairs(entries or {}) do
        if isElement(entry.element) then
            billboards[entry.id] = { id = entry.id, element = entry.element, streamed = false }
            lastBillboardsList[#lastBillboardsList + 1] = {
                id = tonumber(entry.id),
                x = tonumber(entry.x) or 0,
                y = tonumber(entry.y) or 0,
                z = tonumber(entry.z) or 0,
                rz = tonumber(entry.rz) or 0,
                interior = tonumber(entry.interior) or 0,
                dimension = tonumber(entry.dimension) or 0
            }
        end
    end

    ads, adsById = {}, {}
    for _, entry in ipairs(adsList or {}) do
        local id = tonumber(entry.id)
        if id then
            ads[#ads + 1] = { id = id, duration = entry.duration, hash = entry.hash, ext = entry.ext }
            adsById[id] = ads[#ads]
            local path = getCachePath(entry.hash, entry.ext)
            if not adAssets[id] and fileExists(path) then
                createAssetsFromPath(id, entry.hash, entry.ext, path)
            end
        end
    end

    for id in pairs(adAssets) do
        if not adsById[id] then destroyAdAssets(id) end
    end
    setActiveAdByIndex(currentIndex)
    streamTick()
end)

addEvent("BillboardAds:SetActiveAd", true)
addEventHandler("BillboardAds:SetActiveAd", resourceRoot, setActiveAdByIndex)

addEvent("BillboardAds:CacheImage", true)
addEventHandler("BillboardAds:CacheImage", resourceRoot, function(adId, hash, ext, data)
    local id = tonumber(adId)
    local expected = id and adsById[id]
    if not id or type(data) ~= "string" or data == "" then return end
    if type(hash) ~= "string" or not hash:match("^[%da-fA-F]+$") or #hash ~= 32 then return end
    if type(ext) ~= "string" or (ext ~= "png" and ext ~= "jpg") then return end
    if expected and (hash ~= expected.hash or ext ~= expected.ext) then return end
    if #data > (tonumber(Config.MaxImageBytes) or (2 * 1024 * 1024)) or md5(data) ~= hash then return end
    if adAssets[id] and adAssets[id].hash == hash and isElement(adAssets[id].shader) then return end

    destroyAdAssets(id, false, true)
    local path = getCachePath(hash, ext)
    if not writeCacheFile(path, data) then return end
    if not createAssetsFromPath(id, hash, ext, path) then
        if fileExists(path) then fileDelete(path) end
        return
    end

    if pendingActiveAdId == id or (activeAdIndex and ads[activeAdIndex] and ads[activeAdIndex].id == id) then
        pendingActiveAdId = nil
        setActiveAdId(id)
    elseif activeAdId == id then
        local shader = adAssets[id] and adAssets[id].shader
        if shader then
            for _, billboard in pairs(billboards) do
                if billboard.streamed then applyShaderToBillboard(billboard, shader) end
            end
        end
    end
end)

addEvent("BillboardAds:RemoveImage", true)
addEventHandler("BillboardAds:RemoveImage", resourceRoot, function(adId)
    local id = tonumber(adId)
    if not id then return end
    if activeAdId == id then setActiveAdId(nil) end
    destroyAdAssets(id)
end)

addEvent("AdsUI:Close", true)
addEventHandler("AdsUI:Close", root, closePanel)

addEvent("AdsUI:SetLanguage", true)
addEventHandler("AdsUI:SetLanguage", root, function(lang)
    if lang == "ar" or lang == "en" or lang == "es" or lang == "pt" or lang == "tr" then savedLang = lang end
end)

addEvent("AdsUI:CopyUrl", true)
addEventHandler("AdsUI:CopyUrl", root, function(url)
    setClipboard(tostring(url or Config.DefaultUploadSite))
    pushToast("success", "The upload-site URL was copied to the clipboard.")
end)

addEvent("AdsUI:RequestPreview", true)
addEventHandler("AdsUI:RequestPreview", root, function(url, targetView, requestId)
    local view = targetView == "admin" and "admin" or "submit"
    triggerServerEvent("BillboardAds:RequestPreview", resourceRoot, tostring(url or ""), view, tonumber(requestId) or 0)
end)

local function executePreviewPayload(view, requestId, dataUri)
    local chunkSize = math.max(8000, math.min(48000, tonumber(Config.PreviewChunkSize) or 40000))
    local totalChunks = math.ceil(#dataUri / chunkSize)
    local beginCall = "beginServerPreview(" .. table.concat({
        encodeJSArgument(tonumber(requestId) or 0),
        encodeJSArgument(view),
        encodeJSArgument(totalChunks)
    }, ",") .. ");"
    if not executeBrowserJavascript(adsBrowser, beginCall) then return false end

    for index = 1, totalChunks do
        local chunk = dataUri:sub((index - 1) * chunkSize + 1, index * chunkSize)
        local arguments = table.concat({
            encodeJSArgument(tonumber(requestId) or 0),
            encodeJSArgument(view),
            encodeJSArgument(index),
            encodeJSArgument(chunk)
        }, ",")
        if not executeBrowserJavascript(adsBrowser, "appendServerPreviewChunk(" .. arguments .. ");") then return false end
    end

    local finishCall = "finishServerPreview(" .. table.concat({
        encodeJSArgument(tonumber(requestId) or 0),
        encodeJSArgument(view)
    }, ",") .. ");"
    return executeBrowserJavascript(adsBrowser, finishCall) == true
end

addEvent("BillboardAds:PreviewResult", true)
addEventHandler("BillboardAds:PreviewResult", resourceRoot, function(ok, dataOrErr, targetView, requestId)
    if not isElement(adsBrowser) or not browserReady then return end
    local view = targetView == "admin" and "admin" or "submit"
    local payload = tostring(dataOrErr or "")
    if ok and #payload > 48000 then
        if not executePreviewPayload(view, tonumber(requestId) or 0, payload) then
            pushToast("error", "Could not deliver the image preview to the browser. Try a smaller image.")
        end
    else
        local arguments = table.concat({
            encodeJSArgument(ok == true),
            encodeJSArgument(payload),
            encodeJSArgument(view),
            encodeJSArgument(tonumber(requestId) or 0)
        }, ",")
        executeBrowserJavascript(adsBrowser, "onServerPreviewReceived(" .. arguments .. ");")
    end
    if not ok and payload ~= "" then pushToast("error", payload) end
end)

addEvent("AdsUI:SubmitAd", true)
addEventHandler("AdsUI:SubmitAd", root, function(url, hours, seconds)
    triggerServerEvent("BillboardAds:SubmitAd", resourceRoot, url, tonumber(hours), tonumber(seconds))
end)

addEvent("AdsUI:RequestAdminList", true)
addEventHandler("AdsUI:RequestAdminList", root, function()
    triggerServerEvent("BillboardAds:RequestAdminList", resourceRoot)
end)

addEvent("AdsUI:AdminAction", true)
addEventHandler("AdsUI:AdminAction", root, function(action, adId)
    triggerServerEvent("BillboardAds:AdminAction", resourceRoot, tostring(action), tonumber(adId))
end)

addEvent("AdsUI:BillboardAction", true)
addEventHandler("AdsUI:BillboardAction", root, function(action, billboardId, val, x, y, z, rz, interior, dimension)
    if action == "toggle3d" then
        showBillboardIds3D = not showBillboardIds3D
        pushToast("success", showBillboardIds3D and "Billboard IDs are now visible." or "Billboard IDs are now hidden.")
        return
    end
    triggerServerEvent(
        "BillboardAds:BillboardAction",
        resourceRoot,
        tostring(action),
        tonumber(billboardId),
        tonumber(val),
        tonumber(x), tonumber(y), tonumber(z), tonumber(rz), tonumber(interior), tonumber(dimension)
    )
end)

addEvent("BillboardAds:PlacementValues", true)
addEventHandler("BillboardAds:PlacementValues", resourceRoot, function(x, y, z, rz, interior, dimension)
    if not isElement(adsBrowser) or not browserReady or not canBuildBillboards then return end
    local arguments = table.concat({
        encodeJSArgument(tonumber(x) or 0),
        encodeJSArgument(tonumber(y) or 0),
        encodeJSArgument(tonumber(z) or 0),
        encodeJSArgument(tonumber(rz) or 0),
        encodeJSArgument(tonumber(interior) or 0),
        encodeJSArgument(tonumber(dimension) or 0)
    }, ",")
    executeBrowserJavascript(adsBrowser, "setBillboardPlacementValues(" .. arguments .. ");")
end)

addEvent("BillboardAds:OpenUI", true)
addEventHandler("BillboardAds:OpenUI", resourceRoot, function(mode, isAdmin, isBuilder)
    openPanel(mode or "submit", isAdmin, isBuilder)
end)

addEvent("BillboardAds:ReceiveAdminList", true)
addEventHandler("BillboardAds:ReceiveAdminList", resourceRoot, function(list, serverNow, billboardsList, isAdmin, isBuilder)
    lastAdminList = list or {}
    lastServerNow = tonumber(serverNow) or 0
    if type(billboardsList) == "table" then
        lastBillboardsList = sanitizeBillboardsForJSON(billboardsList)
    end
    canAccessAdmin = (isAdmin == true)
    canBuildBillboards = (isBuilder == true)
    pushAdminDataToBrowser()
end)

addEvent("BillboardAds:SubmitResult", true)
addEventHandler("BillboardAds:SubmitResult", resourceRoot, function(ok, msg)
    pushToast(ok and "success" or "error", msg)
    if ok and isElement(adsBrowser) and browserReady then
        executeBrowserJavascript(adsBrowser, "onAdSubmitSuccess();")
    end
end)

addEvent("BillboardAds:AdminResult", true)
addEventHandler("BillboardAds:AdminResult", resourceRoot, function(ok, msg)
    pushToast(ok and "success" or "error", msg)
end)

local function getNearbyAdsPed()
    local px, py, pz = getElementPosition(localPlayer)
    local maxDist = Config.Ped.InteractionDistance or 4.5
    for _, ped in ipairs(getElementsByType("ped", resourceRoot, true)) do
        if getElementData(ped, "BillboardAds:Ped") then
            local ex, ey, ez = getElementPosition(ped)
            if getDistanceBetweenPoints3D(px, py, pz, ex, ey, ez) <= maxDist then
                return ped, ex, ey, ez
            end
        end
    end
    return nil
end

addEventHandler("onClientRender", root, function()
    if next(fadeJobs) ~= nil then
        local now = getTickCount()
        for shader, job in pairs(fadeJobs) do
            if not isElement(shader) then
                fadeJobs[shader] = nil
            else
                local progress = (now - job.startTick) / job.duration
                if progress >= 1 then
                    dxSetShaderValue(shader, "gBlend", 1)
                    fadeJobs[shader] = nil
                    renderingAdId = activeAdId
                    previousActiveAdId = nil
                    local cleanup = {}
                    for id, keepFile in pairs(pendingAssetCleanup) do
                        if id ~= activeAdId then cleanup[#cleanup + 1] = { id = id, keepFile = keepFile } end
                    end
                    for _, item in ipairs(cleanup) do destroyAdAssets(item.id, item.keepFile) end
                else
                    dxSetShaderValue(shader, "gBlend", progress)
                end
            end
        end
    end

    if not isPanelOpen then
        local ped, ex, ey, ez = getNearbyAdsPed()
        if ped then
            local sx, sy = getScreenFromWorldPosition(ex, ey, ez + 1.08)
            if sx and sy then
                local key = (Config.Ped.InteractionKey or "E"):upper()
                local text = string.format("Advertising Clerk\n[Press %s or click]", key)
                dxDrawText(text, sx + 1, sy + 1, sx + 1, sy + 1, tocolor(0, 0, 0, 200), 1.0, "default-bold", "center", "center")
                dxDrawText(text, sx, sy, sx, sy, tocolor(241, 242, 245, 240), 1.0, "default-bold", "center", "center")
            end
        end
    end

    if showBillboardIds3D then
        local cx, cy, cz = getCameraMatrix()
        if cx then
            for _, b in pairs(billboards) do
                if isElement(b.element) then
                    local bx, by, bz = getElementPosition(b.element)
                    local dist = getDistanceBetweenPoints3D(cx, cy, cz, bx, by, bz)
                    if dist <= 80 then
                        local sx, sy = getScreenFromWorldPosition(bx, by, bz + 2.2)
                        if sx and sy then
                            local label = string.format("Billboard #%d (%.0fm)", b.id, dist)
                            dxDrawText(label, sx + 1, sy + 1, sx + 1, sy + 1, tocolor(0, 0, 0, 220), 1.1, "default-bold", "center", "bottom")
                            dxDrawText(label, sx, sy, sx, sy, tocolor(61, 220, 132, 245), 1.1, "default-bold", "center", "bottom")
                        end
                    end
                end
            end
        end
    end
end)

bindKey(Config.Ped.InteractionKey or "e", "down", function()
    if not isPanelOpen then triggerServerEvent("BillboardAds:InteractPed", resourceRoot) end
end)

addEventHandler("onClientClick", root, function(_, state, _, _, _, _, _, clicked)
    if not isPanelOpen and state == "down" and isElement(clicked) and getElementData(clicked, "BillboardAds:Ped") then
        if getNearbyAdsPed() == clicked then
            triggerServerEvent("BillboardAds:InteractPed", resourceRoot)
        end
    end
end)

addEventHandler("onClientResourceStart", resourceRoot, function()
    cleanupCacheFiles()
    loadBillboardModel()
    streamTimer = setTimer(streamTick, Config.StreamIntervalMs, 0)
    triggerServerEvent("BillboardAds:ClientReady", resourceRoot)
end)

addEventHandler("onClientResourceStop", resourceRoot, function()
    closePanel()
    if isTimer(streamTimer) then killTimer(streamTimer) end
    streamTimer = nil
    for _, billboard in pairs(billboards) do removeShaderFromBillboard(billboard) end
    for _, assets in pairs(adAssets) do
        if isElement(assets.shader) then destroyElement(assets.shader) end
        if isElement(assets.texture) then destroyElement(assets.texture) end
    end
    adAssets = {}
    fadeJobs = {}
    pendingAssetCleanup = {}
    cleanupCacheFiles()
end)
