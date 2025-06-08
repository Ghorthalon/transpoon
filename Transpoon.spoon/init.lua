-- Transpoon.spoon: Advanced Translation Service for Hammerspoon
-- Enhanced with multiple providers and API key management inspired by NVDA TranslateAdvanced

local Transpoon = {}

-- Spoon metadata
Transpoon.name = "Transpoon"
Transpoon.version = "2.1"
Transpoon.author = "Guillem Leon <guilevi2000@gmail.com>"
Transpoon.license = "UnLicense"
Transpoon.homepage = "https://github.com/guilevi2000/Transpoon"

-- Configuration
Transpoon.autoTranslate = false
Transpoon.substituteNumbers = true  -- Enable smart number substitution in cache lookups
Transpoon.logger = hs.logger.new('Transpoon')

-- State variables
local lastPhrase = "meow"
local lastTranslatedText = "meow"
local autoTranslateTimer
local transHotkey, clipTransHotkey, autoTranslateHotkey, toLangHotkey
local providerHotkey, toggleProviderHotkey

-- ============================================
-- API CONFIGURATION SYSTEM
-- ============================================

-- Path to external API configuration file
local apiConfigPath = os.getenv("HOME") .. "/.hammerspoon/transpoon_apis.json"

-- ============================================
-- TRANSLATION CACHE SYSTEM
-- ============================================

-- Path to translation cache file
local translationCachePath = os.getenv("HOME") .. "/.hammerspoon/transpoon_cache.json"

-- In-memory translation cache
local translationCache = {}

-- Maximum cache entries (to prevent unlimited growth)
local maxCacheEntries = 10000

-- Generate cache key for translation
local function generateCacheKey(text, from, to)
    -- Create a normalized key: lowercase text + language pair
    local normalizedText = text:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return string.format("%s|%s|%s", normalizedText, from or "auto", to or "en")
end

-- ============================================
-- NUMBER SUBSTITUTION CACHE SYSTEM
-- ============================================

-- Generate cache key with number substitution pattern for smart cache lookups
local function generateNumberSubstitutionKey(text, from, to)
    -- Replace all numbers with a placeholder pattern
    local normalizedText = text:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local numberPattern = normalizedText:gsub("%d+", "##NUMBER##")
    return string.format("%s|%s|%s", numberPattern, from or "auto", to or "en")
end

-- Extract numbers from text in order
local function extractNumbers(text)
    local numbers = {}
    for num in text:gmatch("%d+") do
        table.insert(numbers, num)
    end
    return numbers
end

-- Substitute numbers in translated text
local function substituteNumbersInTranslation(translationTemplate, originalNumbers)
    local result = translationTemplate
    local numberIndex = 1
    
    -- Replace ##NUMBER## placeholders with actual numbers from original text
    result = result:gsub("##NUMBER##", function()
        local number = originalNumbers[numberIndex]
        numberIndex = numberIndex + 1
        return number or "##NUMBER##"  -- fallback if we run out of numbers
    end)
    
    return result
end

-- Load translation cache from file
function Transpoon:loadTranslationCache()
    local file = io.open(translationCachePath, "r")
    if not file then
        self.logger.i("No translation cache file found, starting with empty cache")
        translationCache = {}
        return
    end
    
    local content = file:read("*all")
    file:close()
    
    local success, cache = pcall(hs.json.decode, content)
    if success and cache then
        translationCache = cache
        local count = 0
        for _ in pairs(translationCache) do count = count + 1 end
        self.logger.i("Loaded translation cache with", count, "entries")
    else
        self.logger.e("Failed to parse translation cache file, starting with empty cache")
        translationCache = {}
    end
end

-- Save translation cache to file
function Transpoon:saveTranslationCache()
    -- Limit cache size by removing oldest entries if necessary
    local cacheEntries = {}
    for key, entry in pairs(translationCache) do
        table.insert(cacheEntries, {key = key, entry = entry})
    end
    
    -- Sort by timestamp (newest first)
    table.sort(cacheEntries, function(a, b)
        return (a.entry.timestamp or 0) > (b.entry.timestamp or 0)
    end)
    
    -- Keep only the most recent entries
    if #cacheEntries > maxCacheEntries then
        local newCache = {}
        for i = 1, maxCacheEntries do
            newCache[cacheEntries[i].key] = cacheEntries[i].entry
        end
        translationCache = newCache
        self.logger.i("Trimmed translation cache to", maxCacheEntries, "entries")
    end
    
    local file = io.open(translationCachePath, "w")
    if file then
        file:write(hs.json.encode(translationCache))
        file:close()
        local count = 0
        for _ in pairs(translationCache) do count = count + 1 end
        self.logger.i("Saved translation cache with", count, "entries")
    else
        self.logger.e("Failed to save translation cache to file")
    end
end

-- Get cached translation
function Transpoon:getCachedTranslation(text, from, to)
    -- First, try exact match
    local key = generateCacheKey(text, from, to)
    local cached = translationCache[key]
    
    if cached then
        -- Update access timestamp
        cached.lastAccessed = os.time()
        cached.accessCount = (cached.accessCount or 0) + 1
        
        self.logger.d("Cache hit (exact) for:", text)
        return cached.translation
    end
    
    -- If substituteNumbers is enabled and no exact match, try number substitution
    if self.substituteNumbers and text:match("%d+") then
        local numberSubKey = generateNumberSubstitutionKey(text, from, to)
        local numberCached = translationCache[numberSubKey]
        
        if numberCached then
            -- Extract numbers from original text
            local originalNumbers = extractNumbers(text)
            
            -- Substitute numbers in the cached translation
            local substitutedTranslation = substituteNumbersInTranslation(numberCached.translation, originalNumbers)
            
            -- Update access timestamp for the pattern cache entry
            numberCached.lastAccessed = os.time()
            numberCached.accessCount = (numberCached.accessCount or 0) + 1
            
            self.logger.d("Cache hit (number substitution) for:", text, "->", substitutedTranslation)
            return substitutedTranslation
        end
    end
    
    return nil
end

-- Store translation in cache
function Transpoon:storeCachedTranslation(text, from, to, translation, provider)
    local key = generateCacheKey(text, from, to)
    
    translationCache[key] = {
        originalText = text,
        translation = translation,
        fromLang = from,
        toLang = to,
        provider = provider,
        timestamp = os.time(),
        lastAccessed = os.time(),
        accessCount = 1
    }
    
    -- If substituteNumbers is enabled and text contains numbers, 
    -- also store a number pattern version for future substitutions
    if self.substituteNumbers and text:match("%d+") then
        local numberSubKey = generateNumberSubstitutionKey(text, from, to)
        local numberPatternTranslation = translation:gsub("%d+", "##NUMBER##")
        
        translationCache[numberSubKey] = {
            originalText = text:gsub("%d+", "##NUMBER##"),
            translation = numberPatternTranslation,
            fromLang = from,
            toLang = to,
            provider = provider,
            timestamp = os.time(),
            lastAccessed = os.time(),
            accessCount = 1,
            isNumberPattern = true  -- Mark this as a pattern cache entry
        }
        
        self.logger.d("Cached number pattern:", text:gsub("%d+", "##NUMBER##"), "->", numberPatternTranslation)
    end
    
    self.logger.d("Cached translation:", text, "->", translation)
    
    -- Save cache periodically (every 10 new entries)
    local count = 0
    for _ in pairs(translationCache) do count = count + 1 end
    if count % 10 == 0 then
        self:saveTranslationCache()
    end
end

-- Clear translation cache
function Transpoon:clearTranslationCache()
    translationCache = {}
    local file = io.open(translationCachePath, "w")
    if file then
        file:write("{}")
        file:close()
        self.logger.i("Translation cache cleared")
    end
end

-- Get cache statistics
function Transpoon:getCacheStats()
    local count = 0
    local totalSize = 0
    local oldestTimestamp = nil
    local newestTimestamp = nil
    
    for _, entry in pairs(translationCache) do
        count = count + 1
        totalSize = totalSize + #entry.originalText + #entry.translation
        
        if not oldestTimestamp or entry.timestamp < oldestTimestamp then
            oldestTimestamp = entry.timestamp
        end
        if not newestTimestamp or entry.timestamp > newestTimestamp then
            newestTimestamp = entry.timestamp
        end
    end
    
    return {
        entryCount = count,
        totalSize = totalSize,
        oldestEntry = oldestTimestamp and os.date("%Y-%m-%d %H:%M:%S", oldestTimestamp) or "N/A",
        newestEntry = newestTimestamp and os.date("%Y-%m-%d %H:%M:%S", newestTimestamp) or "N/A"
    }
end

-- Load API configuration from external JSON file
function Transpoon:loadApiConfig()
    local file = io.open(apiConfigPath, "r")
    if not file then
        self.logger.i("No API config file found, creating default configuration")
        self:createDefaultApiConfig()
        return self:loadApiConfig()
    end
    
    local content = file:read("*all")
    file:close()
    
    local success, config = pcall(hs.json.decode, content)
    if not success then
        self.logger.e("Failed to parse API config file:", config)
        return {}
    end
    
    return config or {}
end

-- Create default API configuration file
function Transpoon:createDefaultApiConfig()
    local defaultConfig = {
        deepl = {
            api_key = "",
            use_free_api = true,
            enabled = false,
            description = "Get your free API key from https://www.deepl.com/pro/change-plan#developer"
        },
        libretranslate = {
            api_key = "",
            api_url = "https://translate.nvda.es/translate",
            enabled = false,
            description = "Donation-based service, contact NVDA.es community for API key"
        },
        openai = {
            api_key = "",
            model = "gpt-4o-mini",
            enabled = false,
            description = "Get from https://platform.openai.com/api-keys"
        },
        microsoft = {
            use_auth = true,
            enabled = false,
            description = "Uses free authentication approach from TranslateAdvanced"
        }
    }
    
    local file = io.open(apiConfigPath, "w")
    if file then
        file:write(hs.json.encode(defaultConfig))
        file:close()
        self.logger.i("Created default API config at:", apiConfigPath)
    else
        self.logger.e("Failed to create API config file at:", apiConfigPath)
    end
end

-- Open API configuration file for editing
function Transpoon:openApiConfigFile()
    hs.execute("open " .. apiConfigPath)
end

-- Set API key for a specific service
function Transpoon:setApiKey(service, apiKey)
    local config = self:loadApiConfig()
    if not config[service] then
        config[service] = {}
    end
    config[service].api_key = apiKey
    config[service].enabled = true
    
    local file = io.open(apiConfigPath, "w")
    if file then
        file:write(hs.json.encode(config))
        file:close()
        self.logger.i("Updated API key for service:", service)
        return true
    else
        self.logger.e("Failed to save API config")
        return false
    end
end

-- Get API configuration for a service
function Transpoon:getApiConfig(service)
    local config = self:loadApiConfig()
    return config[service] or {}
end

-- ============================================
-- TRANSLATION PROVIDERS
-- ============================================

local lastPhraseScript = [[
global spokenPhrase

tell application "VoiceOver"
	set spokenPhrase to the content of the last phrase
end tell

spokenPhrase
]]

local function getLastPhrase()
    if hs.application.get("VoiceOver") == nil then
        print("DEBUG: VoiceOver application not found")
        return
    end

    local success, result, output = hs.osascript.applescript(lastPhraseScript)
    if not success then
        print("DEBUG: AppleScript failed:", hs.inspect and hs.inspect(output) or tostring(output))
        return
    end

    if result:match("^%s*$") then
        print("DEBUG: Empty or whitespace-only result")
        return
    end

    print("DEBUG: Got phrase from VoiceOver:", hs.inspect and hs.inspect(result) or tostring(result))
    return result
end

-- Translation service providers
local translationProviders = {
    {
        name = "Google Translate",
        id = "google",
        enabled = true,
        urls = {
            -- Primary: Mobile endpoint used by NVDA translate addon (most reliable)
            'http://translate.google.com/m?hl={to}&sl={from}&q={query}',
            -- Fallback: API endpoints
            'https://translate.googleapis.com/translate_a/single?client=gtx&sl={from}&tl={to}&dt=t&q={query}',
            'https://translate.google.com/translate_a/single?client=gtx&sl={from}&tl={to}&dt=t&q={query}',
            'https://translate.google.co.kr/translate_a/single?client=gtx&sl={from}&tl={to}&dt=t&q={query}'
        },
        parseResponse = function(result)
            -- First try to parse HTML response from mobile endpoint (NVDA approach)
            local translated = result:match('class="result%-container">(.-)<')
            if translated then
                -- Unescape HTML entities
                translated = translated:gsub("&lt;", "<"):gsub("&gt;", ">")
                    :gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'")
                return translated
            end
            
            -- Fallback to JSON parsing for API endpoints
            local success, json = pcall(hs.json.decode, result)
            if success and json and json[1] then
                local translationResult = ""
                for _, v in pairs(json[1]) do
                    if v[1] then
                        translationResult = translationResult .. v[1]
                    end
                end
                return translationResult ~= "" and translationResult or nil
            end
            return nil
        end,
        getHeaders = function()
            return {
                -- Use the same User-Agent as NVDA translate addon for consistency
                ["User-Agent"] = 'Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1; SV1; .NET CLR 1.1.4322; ' ..
                               '.NET CLR 2.0.50727; .NET CLR 3.0.04506.30)'
            }
        end
    },
    {
        name = "LibreTranslate",
        id = "libre",
        enabled = true,
        urls = {
            'https://libretranslate.de/translate',
            'https://libretranslate.com/translate'
        },
        method = "POST",
        parseResponse = function(result)
            local success, json = pcall(hs.json.decode, result)
            if success and json and json.translatedText then
                return json.translatedText
            end
            return nil
        end,
        preparePayload = function(text, from, to)
            return hs.json.encode({
                q = text,
                source = from == "auto" and "auto" or from,
                target = to,
                format = "text"
            })
        end
    },
    {
        name = "MyMemory",
        id = "mymemory",
        enabled = true,
        urls = {
            'https://api.mymemory.translated.net/get?q={query}&langpair={from}|{to}'
        },
        parseResponse = function(result)
            local success, json = pcall(hs.json.decode, result)
            if success and json and json.responseData and json.responseData.translatedText then
                return json.responseData.translatedText
            end
            return nil
        end
    },
    {
        name = "Lingva Translate",
        id = "lingva",
        enabled = true,
        urls = {
            'https://lingva.ml/api/v1/{from}/{to}/{query}',
            'https://translate.plausibility.cloud/api/v1/{from}/{to}/{query}',
            'https://translate.projectsegfau.lt/api/v1/{from}/{to}/{query}',
            'https://translate.dr460nf1r3.org/api/v1/{from}/{to}/{query}'
        },
        parseResponse = function(result)
            local success, json = pcall(hs.json.decode, result)
            if success and json and json.translation then
                return json.translation
            end
            return nil
        end
    },
    {
        name = "Microsoft Translate",
        id = "microsoft",
        enabled = true,  -- Using TranslateAdvanced authentication method
        authUrl = 'https://edge.microsoft.com/translate/auth',
        translateUrl = 'https://api-edge.cognitive.microsofttranslator.com/translate',
        method = "POST",
        requiresAuth = true,
        authToken = nil,
        tokenExpiry = 0,
        parseResponse = function(result)
            local success, json = pcall(hs.json.decode, result)
            if success and json and json[1] and json[1].translations and json[1].translations[1] then
                return json[1].translations[1].text
            end
            return nil
        end,
        getAuthToken = function(self)
            -- Check if we have a valid token
            local currentTime = os.time()
            if self.authToken and currentTime < self.tokenExpiry then
                return self.authToken
            end
            
            -- Get new JWT token from Microsoft Edge auth endpoint
            local headers = {
                ["User-Agent"] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' ..
                               '(KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36 Edg/116.0.1938.69',
                ["Accept"] = '*/*',
                ["Accept-Language"] = 'en-US,en;q=0.9',
                ["Referer"] = 'https://appsumo.com/'
            }
            
            local response, result = hs.http.get(self.authUrl, headers)
            if response == 200 and result then
                -- The response should be a JWT token
                self.authToken = result:gsub('"', '') -- Remove quotes if present
                -- JWT tokens from Microsoft typically expire in 10 minutes
                self.tokenExpiry = currentTime + 600
                return self.authToken
            end
            
            return nil
        end,
        getHeaders = function(self)
            local token = self:getAuthToken()
            if not token then
                return nil
            end
            
            return {
                ["Authorization"] = 'Bearer ' .. token,
                ["Content-Type"] = 'application/json',
                ["User-Agent"] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' ..
                               '(KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36 Edg/116.0.1938.69',
                ["Accept"] = 'application/json',
                ["Accept-Language"] = 'en-US,en;q=0.9',
                ["Referer"] = 'https://appsumo.com/'
            }
        end,
        preparePayload = function(text, from, to)
            return hs.json.encode({
                {
                    Text = text
                }
            })
        end,
        buildUrl = function(self, text, from, to)
            local params = {
                'api-version=3.0',
                'from=' .. (from == 'auto' and '' or from),
                'to=' .. to
            }
            return self.translateUrl .. '?' .. table.concat(params, '&')
        end
    },
    {
        name = "DeepL Translate",
        id = "deepl",
        enabled = false,  -- Requires API key
        method = "POST",
        parseResponse = function(result)
            local success, json = pcall(hs.json.decode, result)
            if success and json and json.translations and json.translations[1] then
                return json.translations[1].text
            end
            return nil
        end,
        preparePayload = function(text, from, to)
            return hs.json.encode({
                text = {text},
                source_lang = from == "auto" and nil or from:upper(),
                target_lang = to:upper()
            })
        end,
        getHeaders = function(self)
            local config = Transpoon:getApiConfig("deepl")
            if not config.api_key or config.api_key == "" then
                return nil
            end
            
            return {
                ["Authorization"] = "DeepL-Auth-Key " .. config.api_key,
                ["Content-Type"] = "application/json",
                ["User-Agent"] = "Transpoon/2.1"
            }
        end,
        buildUrl = function(self, text, from, to)
            local config = Transpoon:getApiConfig("deepl")
            local baseUrl = config.use_free_api and 
                          "https://api-free.deepl.com/v2/translate" or
                          "https://api.deepl.com/v2/translate"
            return baseUrl
        end,
        requiresAuth = true
    },
    {
        name = "OpenAI Translate",
        id = "openai",
        enabled = true,  -- Requires API key
        method = "POST",
        parseResponse = function(result)
            local success, json = pcall(hs.json.decode, result)
            if success and json and json.choices and json.choices[1] and 
               json.choices[1].message and json.choices[1].message.content then
                return json.choices[1].message.content
            end
            return nil
        end,
        preparePayload = function(text, from, to)
            local prompt = string.format(
                "Translate the following text from %s to %s. Return only the translation, no explanations:\n\n%s",
                from == "auto" and "the detected language" or from,
                to,
                text
            )
            
            local config = Transpoon:getApiConfig("openai")
            local model = config.model or "gpt-4o-mini"
            
            return hs.json.encode({
                model = model,
                messages = {
                    {
                        role = "user",
                        content = prompt
                    }
                },
                max_tokens = 1000,
                temperature = 0.3
            })
        end,
        getHeaders = function(self)
            local config = Transpoon:getApiConfig("openai")
            if not config.api_key or config.api_key == "" then
                return nil
            end
            
            return {
                ["Authorization"] = "Bearer " .. config.api_key,
                ["Content-Type"] = "application/json",
                ["User-Agent"] = "Transpoon/2.1"
            }
        end,
        buildUrl = function(self, text, from, to)
            return "https://api.openai.com/v1/chat/completions"
        end,
        requiresAuth = true
    },
    {
        name = "Argos Translate",
        id = "argos",
        enabled = false,  -- Disabled by default as it requires local setup
        urls = {
            'http://localhost:5000/translate'
        },
        method = "POST",
        parseResponse = function(result)
            local success, json = pcall(hs.json.decode, result)
            if success and json and json.translatedText then
                return json.translatedText
            end
            return nil
        end,
        preparePayload = function(text, from, to)
            return hs.json.encode({
                q = text,
                source = from == "auto" and "en" or from,
                target = to
            })
        end
    }
}

local function getActiveProviders()
    local active = {}
    for _, provider in ipairs(translationProviders) do
        if provider.enabled then
            table.insert(active, provider)
        end
    end
    return active
end

local function tryProvider(provider, text, from, to)
    print("DEBUG: Trying provider:", provider.name)
    
    -- Handle providers that require authentication and custom URL building
    if provider.requiresAuth then
        local authHeaders = provider:getHeaders()
        if not authHeaders then
            print("DEBUG:", provider.name, "authentication failed")
            return nil
        end
        
        local url = provider:buildUrl(text, from, to)
        local payload = provider.preparePayload(text, from, to)
        
        local response, result = hs.http.post(url, payload, authHeaders)
        
        if response == 200 and result then
            local translationResult = provider.parseResponse(result)
            if translationResult and translationResult ~= "" then
                print("DEBUG: Translation successful with", provider.name)
                return translationResult
            end
        else
            print("DEBUG:", provider.name, "failed with response code:", response)
        end
        
        return nil
    end
    
    -- Handle standard providers
    local query = hs.http.encodeForQuery(text)
    local headers = {
        ["User-Agent"] = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
        ["Accept"] = 'application/json, text/plain, */*',
        ["Accept-Language"] = 'en-US,en;q=0.9'
    }
    
    -- Use provider-specific headers if available
    if provider.getHeaders then
        local providerHeaders = provider.getHeaders()
        if providerHeaders then
            for k, v in pairs(providerHeaders) do
                headers[k] = v
            end
        end
    end
    
    -- Handle providers with custom URL lists
    local urls = provider.urls or {}
    if #urls == 0 then
        print("DEBUG: Provider", provider.name, "has no URLs configured")
        return nil
    end
    
    for i, urlTemplate in ipairs(urls) do
        local url = urlTemplate
        url = url:gsub("{query}", function() return query end)
        url = url:gsub("{from}", function() return from end)
        url = url:gsub("{to}", function() return to end)
        print("DEBUG: Trying URL", i, "for provider", provider.name)
        
        local response, result
        
        if provider.method == "POST" then
            headers["Content-Type"] = "application/json"
            local payload = provider.preparePayload and provider.preparePayload(text, from, to) or ""
            response, result = hs.http.post(url, payload, headers)
        else
            response, result = hs.http.get(url, headers)
        end
        
        if response == 200 and result then
            local translationResult = provider.parseResponse(result)
            if translationResult and translationResult ~= "" then
                print("DEBUG: Translation successful with provider", provider.name, "URL", i)
                return translationResult
            end
        else
            print("DEBUG: Provider", provider.name, "URL", i, "failed with response code:", response)
        end
    end
    
    print("DEBUG: Provider", provider.name, "failed")
    return nil
end

local function translateText(text, from, to)
    -- First check if we have this translation cached
    local cachedTranslation = Transpoon:getCachedTranslation(text, from, to)
    if cachedTranslation then
        print("DEBUG: Using cached translation for:", text)
        return cachedTranslation
    end
    
    local activeProviders = getActiveProviders()
    
    -- Get preferred provider from settings, default to first active provider
    local preferredProviderId = hs.settings.get('transpoon.preferredProvider') or
                               (activeProviders[1] and activeProviders[1].id)
    
    -- Find preferred provider and move it to front
    for i, provider in ipairs(activeProviders) do
        if provider.id == preferredProviderId then
            table.remove(activeProviders, i)
            table.insert(activeProviders, 1, provider)
            break
        end
    end
    
    -- Try each active provider in order
    for _, provider in ipairs(activeProviders) do
        local result = tryProvider(provider, text, from, to)
        if result then
            -- Store successful translation in cache
            Transpoon:storeCachedTranslation(text, from, to, result, provider.name)
            return result
        end
    end
    
    -- If all providers fail, return original text
    print("DEBUG: All translation providers failed, returning original text")
    return text
end

local function setTranslationProvider()
    local activeProviders = getActiveProviders()
    
    if #activeProviders == 0 then
        hs.alert.show("No translation providers enabled!")
        return
    end
    
    local current = hs.settings.get('transpoon.preferredProvider') or
                   (activeProviders[1] and activeProviders[1].id)
    local currentName = ""
    for _, provider in ipairs(activeProviders) do
        if provider.id == current then
            currentName = provider.name
            break
        end
    end
    
    local chooser = hs.chooser.new(function(choice)
        if choice then
            hs.settings.set('transpoon.preferredProvider', choice.providerId)
            speak("Translation provider set to " .. choice.text)
        end
    end)
    
    local items = {}
    for _, provider in ipairs(activeProviders) do
        table.insert(items, {
            text = provider.name,
            subText = "Provider ID: " .. provider.id,
            providerId = provider.id
        })
    end
    
    chooser:choices(items)
    chooser:placeholderText("Current: " .. currentName)
    chooser:show()
end

local function toggleProvider()
    local allProviders = translationProviders
    local items = {}
    
    for _, provider in ipairs(allProviders) do
        table.insert(items, {
            text = provider.name .. (provider.enabled and " ✓" or " ✗"),
            subText = "Provider ID: " .. provider.id .. " - " ..
                     (provider.enabled and "Enabled" or "Disabled"),
            provider = provider
        })
    end
    
    local chooser = hs.chooser.new(function(choice)
        if choice then
            choice.provider.enabled = not choice.provider.enabled
            speak(choice.provider.name .. " is now " ..
                 (choice.provider.enabled and "enabled" or "disabled"))
        end
    end)
    
    chooser:choices(items)
    chooser:placeholderText("Toggle translation providers")
    chooser:show()
end

-- ============================================
-- SPEECH AND TRANSLATION FUNCTIONS
-- ============================================

local speakScript = [[
tell application "VoiceOver"
	output "MESSAGE"
end tell
]]

local function speak(text)
    -- We can't pass the supplied message to string.gsub directly,
    -- because gsub uses '%' characters in the replacement string for capture groups
    -- and we can't guarantee that our message doesn't contain any of those.
    print('speaking', hs.inspect and hs.inspect(text) or tostring(text), 'which is a', type(text))
    
    -- Store the translated text we're about to speak to avoid retranslating it
    lastTranslatedText = text
    
    local script = speakScript:gsub("MESSAGE", function ()
        return text
    end)

	if text:match("^%s*$") then
		return
	end

    local success, _, output = hs.osascript.applescript(script)
    if not success then
        print(hs.inspect and hs.inspect(output) or tostring(output))
    end
end

local function checkLastPhrase()
    local phrase = getLastPhrase()
    
    if not phrase or phrase == lastPhrase then
        return
    end
    
    -- Check if this phrase is the same as our last translated text
    -- If so, don't translate it again to avoid infinite loops
    if phrase == lastTranslatedText then
        lastPhrase = phrase  -- Update lastPhrase to prevent continuous checking
        return
    end

    if not Transpoon.autoTranslate then
        print("DEBUG: Auto translate disabled")
        return
    end

    print("DEBUG: Proceeding with translation for phrase:", hs.inspect and hs.inspect(phrase) or tostring(phrase))

    speak(" ￼ ") -- stop VO from speaking the last untranslated phrase
    lastPhrase = phrase
    speak(translateText(phrase, hs.settings.get('transpoon.sourceLanguage'),
                      hs.settings.get('transpoon.destinationLanguage')))
end

local function transLastPhrase()
    return speak(translateText(getLastPhrase(), hs.settings.get('transpoon.sourceLanguage'),
                              hs.settings.get('transpoon.destinationLanguage')))
end

local function transClipboard()
    return speak(translateText(hs.pasteboard.getContents(),
                              hs.settings.get('transpoon.sourceLanguage'),
                              hs.settings.get('transpoon.destinationLanguage')))
end

local function setDestLanguage()
    local btn, text = hs.dialog.textPrompt('Destination language',
                                          'Enter the code for the language to translate into',
                                          hs.settings.get('transpoon.destinationLanguage') or "",
                                          'Set','Open language code reference')
    if btn == 'Open language code reference' then
        return hs.urlevent.openURL("https://cloud.google.com/translate/docs/languages")
    end
    return hs.settings.set('transpoon.destinationLanguage', text)
end

-- ============================================
-- SPOON LIFECYCLE METHODS
-- ============================================

function Transpoon:init()
    self.logger.i("Initializing Transpoon")
    
    -- Set default language settings
    if not hs.settings.get('transpoon.sourceLanguage') then
        hs.settings.set('transpoon.sourceLanguage', 'auto')
    end
    if not hs.settings.get('transpoon.destinationLanguage') then
        hs.settings.set('transpoon.destinationLanguage', hs.host.locale.details().languageCode)
    end
    
    -- Initialize API configuration and translation cache
    self:loadApiConfig()
    self:loadTranslationCache()
    
    -- Initialize cache auto-save timer (save every 5 minutes)
    self.cacheAutoSaveTimer = hs.timer.doEvery(300, function()
        self:saveTranslationCache()
        self.logger.i("Auto-saved translation cache")
    end)
    self.cacheAutoSaveTimer:start()
    
    -- Setup hotkeys
    transHotkey = hs.hotkey.new("ctrl-shift", "t", transLastPhrase)
    clipTransHotkey = hs.hotkey.new("ctrl-shift", "y", transClipboard)
    autoTranslateHotkey = hs.hotkey.new("ctrl-shift", "a", function()
        self.autoTranslate = not self.autoTranslate
        -- speak state
        speak("Auto translation is now " .. (self.autoTranslate and "enabled" or "disabled"))
        -- if active, run the thing
        checkLastPhrase()
        -- start the timer if enabled, stop it if disabled
        if self.autoTranslate then
            if not autoTranslateTimer then
                autoTranslateTimer = hs.timer.doEvery(0.05, checkLastPhrase)
            end
            autoTranslateTimer:start()
        else
            if autoTranslateTimer then
                autoTranslateTimer:stop()
                autoTranslateTimer = nil
            end
        end
    end)
    
    toLangHotkey = hs.hotkey.new("ctrl-shift", "d", setDestLanguage)
    providerHotkey = hs.hotkey.new("ctrl-shift", "p", setTranslationProvider)
    toggleProviderHotkey = hs.hotkey.new("ctrl-shift", "o", toggleProvider)
    
    self.logger.i("Transpoon initialized successfully")
end

function Transpoon:start()
    self.logger.i("Starting Transpoon")
    
    transHotkey:enable()
    autoTranslateHotkey:enable()
    clipTransHotkey:enable()
    toLangHotkey:enable()
    providerHotkey:enable()
    toggleProviderHotkey:enable()
    
    -- Only start the auto-translate timer if auto-translate is enabled
    if self.autoTranslate then
        if not autoTranslateTimer then
            autoTranslateTimer = hs.timer.doEvery(0.1, checkLastPhrase)
        end
        autoTranslateTimer:start()
    end
    
    self.logger.i("Transpoon started successfully")
end

function Transpoon:stop()
    self.logger.i("Stopping Transpoon")
    
    transHotkey:disable()
    clipTransHotkey:disable()
    toLangHotkey:disable()
    providerHotkey:disable()
    toggleProviderHotkey:disable()
    autoTranslateHotkey:disable()
    
    -- Stop cache auto-save timer
    if self.cacheAutoSaveTimer then
        self.cacheAutoSaveTimer:stop()
        self.cacheAutoSaveTimer = nil
    end
    
    -- Stop the auto-translate timer
    if autoTranslateTimer then
        autoTranslateTimer:stop()
        autoTranslateTimer = nil
    end
    
    -- Save translation cache on stop
    self:saveTranslationCache()
    
    self.logger.i("Transpoon stopped successfully")
end

-- ============================================
-- ADDITIONAL METHODS FOR API MANAGEMENT
-- ============================================

-- Hotkey to open API configuration
-- ============================================
-- CACHE MANAGEMENT METHODS
-- ============================================

-- Show cache statistics
function Transpoon:showCacheStats()
    local stats = self:getCacheStats()
    local message = string.format(
        "Translation Cache Statistics:\n" ..
        "Entries: %d\n" ..
        "Total Size: %d bytes\n" ..
        "Oldest: %s\n" ..
        "Newest: %s",
        stats.entryCount,
        stats.totalSize,
        stats.oldestEntry,
        stats.newestEntry
    )
    hs.alert.show(message, 5)
    self.logger.i("Cache stats:", message:gsub("\n", " | "))
end

-- Clear cache with confirmation
function Transpoon:clearCacheWithConfirmation()
    local stats = self:getCacheStats()
    if stats.entryCount == 0 then
        hs.alert.show("Translation cache is already empty")
        return
    end
    
    local result = hs.dialog.blockAlert(
        "Clear Translation Cache",
        string.format("Clear %d cached translations?", stats.entryCount),
        "Clear Cache",
        "Cancel"
    )
    
    if result == "Clear Cache" then
        self:clearTranslationCache()
        hs.alert.show("Translation cache cleared")
        speak("Translation cache cleared")
    end
end

-- Manual cache save
function Transpoon:forceSaveCache()
    self:saveTranslationCache()
    hs.alert.show("Translation cache saved")
end

-- ============================================
-- HOTKEY BINDING
-- ============================================

function Transpoon:bindHotkeys(mapping)
    local def = {
        translate = hs.fnutils.partial(transLastPhrase),
        translateClipboard = hs.fnutils.partial(transClipboard),
        toggleAutoTranslate = hs.fnutils.partial(function()
            self.autoTranslate = not self.autoTranslate
            speak("Auto translation is now " .. (self.autoTranslate and "enabled" or "disabled"))
        end),
        toggleNumberSubstitution = hs.fnutils.partial(function()
            local enabled = self:toggleNumberSubstitution()
            speak("Number substitution is now " .. (enabled and "enabled" or "disabled"))
        end),
        setDestLanguage = hs.fnutils.partial(setDestLanguage),
        chooseProvider = hs.fnutils.partial(setTranslationProvider),
        toggleProvider = hs.fnutils.partial(toggleProvider),
        openApiConfig = hs.fnutils.partial(self.openApiConfigFile, self),
        showCacheStats = hs.fnutils.partial(self.showCacheStats, self),
        clearCache = hs.fnutils.partial(self.clearCacheWithConfirmation, self),
        saveCache = hs.fnutils.partial(self.forceSaveCache, self)
    }
    hs.spoons.bindHotkeysToSpec(def, mapping)
end

-- NOTE: Bing Translate Implementation Issue
-- The current Bing Translate implementation does not work due to Microsoft's
-- authentication requirements. To fix this, you would need to:
-- 1. Implement proper CSRF token extraction from the Bing translator page
-- 2. Handle session management and authentication
-- 3. Use the correct API endpoints with proper headers
-- 
-- For a working implementation, consider using the translators library approach:
-- https://github.com/UlionTse/translators
--
-- Alternative: Enable other providers like Google Translate, LibreTranslate, or MyMemory

return Transpoon
