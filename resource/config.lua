Config = {
    DefaultLanguage = "en",

    BillboardModel = 1916,
    BillboardTextures = { "000001858D3FC5B8", "000001858C7879B8" },
    StreamDistance = 150,
    StreamIntervalMs = 750,
    FadeDurationMs = 1000,

    MaxImageBytes = 2 * 1024 * 1024,
    ImageSizeCheckIntervalMs = 100,
    MaxImageWidth = 2048,
    MaxImageHeight = 1024,
    MaxImagePixels = 2 * 1024 * 1024,
    MaxPreviewCacheEntries = 12,
    MaxPreviewCacheBytes = 8 * 1024 * 1024,
    PreviewBandwidth = 512000,
    PreviewChunkSize = 40000,
    MaxActiveAds = 25,
    MaxBillboards = 250,
    MaxUrlLength = 300,
    DefaultAdDuration = 10,
    MinHours = 1,
    MaxHours = 48,
    MinDisplaySeconds = 5,
    MaxDisplaySeconds = 15,
    PricePerHourPerSecond = 500,
    MaxConcurrentAdsPerPlayer = 3,

    LatentBandwidth = 120000,
    FetchMaxRetries = 3,
    FetchRetryDelayMs = 8000,

    EnforceDomainWhitelist = true,
    DefaultUploadSite = "https://imgbb.com/",
    AllowedDomains = {
        "top4top.io",
        "imgur.com",
        "postimg.cc",
        "ibb.co",
        "catbox.moe",
        "discordapp.com",
        "discordapp.net",
    },

    AdminACLGroups = { "Console", "Admin", "SuperModerator" },
    ModeratorACLGroups = { "Console", "Admin", "SuperModerator", "Moderator" },
    AdminPanelCommand = "billboards",

    Ped = {
        Enabled = true,
        Model = 17,
        X = -2524.13843,
        Y = -623.76709,
        Z = 132.7704,
        RZ = 0,
        Interior = 0,
        Dimension = 0,
        InteractionDistance = 4.5,
        InteractionKey = "e",
        AnimationBlock = "OTB",
        AnimationName = "wtchrace_loop",
    },

}

if not localPlayer then
    Config.Money = {
        Has = function(player, amount)
            return getPlayerMoney(player) >= amount
        end,
        Take = function(player, amount)
            if getPlayerMoney(player) < amount then return false end
            return takePlayerMoney(player, amount)
        end,
        Give = function(player, amount)
            return givePlayerMoney(player, amount)
        end
    }
end
