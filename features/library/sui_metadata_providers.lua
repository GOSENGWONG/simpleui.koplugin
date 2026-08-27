-- sui_metadata_providers.lua — Simple UI
-- Integrates external metadata sources for files whose real bibliographic
-- data (title, author, series) lives outside standard document properties
-- but is recoverable through a companion plugin's own document provider.
--
-- BookInfoManager is the single point Library/covers/series grouping read
-- metadata from (Config.getBookInfoManager(), see infra/sui_config.lua).
-- Rather than teaching every caller about each external source, this module
-- patches BookInfoManager.extractBookInfo once: for a recognized file it
-- temporarily substitutes the external provider so extraction reads through
-- it, then restores the native lookup for every other file.
--
-- Each entry in SOURCES below is self-contained (recognition + provider
-- resolution) so a new external source can be added as one more entry
-- without touching the patch itself.
--
-- getBookInfo is also patched: a cached row for a recognized file that is
-- missing title or authors is evicted and re-extracted once per session,
-- so an incomplete row never lingers in the cache indefinitely.
--
-- Public API
-- ----------
--   Providers.install()  -- idempotent; call once during plugin init

local logger = require("logger")

local Providers = {}

-- ---------------------------------------------------------------------------
-- Companion-app chapter archives (CBZ files produced by a manga/comics
-- reader plugin, tagged with their own origin metadata)
-- ---------------------------------------------------------------------------

local ok_android, android = pcall(require, "android")
local is_android = ok_android and android ~= nil

local function normalizePath(path)
    if type(path) ~= "string" or path == "" then return nil end
    if is_android then
        path = path:gsub("^/sdcard/", "/storage/emulated/0/")
    end
    return path:gsub("/+$", "")
end

local function pathIsInside(path, directory)
    path = normalizePath(path)
    directory = normalizePath(directory)
    if not (path and directory) then return false end

    local dir_prefix = directory
    if dir_prefix:sub(-1) ~= "/" then dir_prefix = dir_prefix .. "/" end
    if path:sub(1, #dir_prefix) ~= dir_prefix then return false end

    local remainder = path:sub(#dir_prefix + 1)
    return remainder ~= "" and not remainder:find("/")
end

local function getDataDir()
    local DataStorage = require("datastorage")
    return DataStorage:getFullDataDir() or DataStorage:getDataDir()
end

local function absoluteDataPath(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" then
        return path
    end
    path = path:gsub("^%./", "")
    return getDataDir() .. "/" .. path
end

-- Reads the trailing ZIP comment directly off disk, without opening the
-- archive as a document — cheap enough to run on every candidate file.
local function readZipComment(path)
    local file = io.open(path, "rb")
    if not file then return nil end

    local size = file:seek("end")
    if not size or size <= 0 then file:close(); return nil end

    local read_size = math.min(size, 65535 + 22)
    file:seek("set", size - read_size)
    local data = file:read(read_size)
    file:close()
    if not data then return nil end

    for pos = read_size - 21, 1, -1 do
        if data:sub(pos, pos + 3) == "PK\005\006" then
            local len_low = data:byte(pos + 20) or 0
            local len_high = data:byte(pos + 21) or 0
            local comment_len = len_low + len_high * 256
            if pos + 21 + comment_len == read_size and comment_len > 0 then
                return data:sub(pos + 22, pos + 21 + comment_len)
            end
        end
    end
end

local origin_metadata_cache = {}
local function hasOriginMetadata(path)
    if origin_metadata_cache[path] ~= nil then
        return origin_metadata_cache[path]
    end
    local comment = readZipComment(path)
    local has_origin = type(comment) == "string"
        and comment:find('"chapter_id"', 1, true) ~= nil
        and comment:find('"manga_id"', 1, true) ~= nil
        and comment:find('"source_id"', 1, true) ~= nil
    origin_metadata_cache[path] = has_origin
    return has_origin
end

local storage_path_loaded = false
local storage_path_cache
local function getChapterStoragePath()
    if storage_path_loaded then return storage_path_cache end
    storage_path_loaded = true

    local home = getDataDir() .. "/rakuyomi"
    local storage = home .. "/downloads"
    local content = require("util").readFromFile(home .. "/settings.json", "rb")
    if content then
        local ok_json, rapidjson = pcall(require, "rapidjson")
        local ok_decode, settings = false, nil
        if ok_json then
            ok_decode, settings = pcall(rapidjson.decode, content)
        end
        if ok_decode and type(settings) == "table"
                and type(settings.storage_path) == "string"
                and settings.storage_path ~= "" then
            storage = absoluteDataPath(settings.storage_path)
        end
    end
    storage_path_cache = normalizePath(storage)
    return storage_path_cache
end

local function isChapterArchive(path)
    if type(path) ~= "string" then return false end
    local storage = getChapterStoragePath()
    return pathIsInside(path, storage) or hasOriginMetadata(path)
end

local function getChapterArchiveProvider(path)
    if type(path) ~= "string" or path:lower():sub(-4) ~= ".cbz"
            or not isChapterArchive(path) then
        return nil
    end
    local ok_cbz, CbzDocument = pcall(require, "extensions/CbzDocument")
    if not (ok_cbz and type(CbzDocument) == "table") then
        return nil
    end

    -- The provider's own document props use a singular "author" key and a
    -- "notes" key, while every reader in this codebase expects the plural
    -- "authors" (matching the bookinfo cache column) and "description".
    -- Patched once, in place, so extraction through this provider always
    -- yields fields the rest of the plugin can actually read.
    if not CbzDocument._simpleui_authors_field_patched then
        CbzDocument._simpleui_authors_field_patched = true
        local orig_getDocumentProps = CbzDocument.getDocumentProps
        function CbzDocument:getDocumentProps(...)
            local props = orig_getDocumentProps(self, ...)
            if props then
                if (not props.authors or props.authors == "") and props.author then
                    props.authors = props.author
                end
                if (not props.description or props.description == "") and props.notes then
                    props.description = props.notes
                end
            end
            return props
        end
    end

    return CbzDocument
end

-- ---------------------------------------------------------------------------
-- External sources known to this module. Each entry is self-contained:
-- getProvider(path) returns the document provider to extract metadata with
-- for a recognized file, or nil for anything it doesn't own. Cheap checks
-- (extension, path) must run before any expensive ones — this runs on
-- every file passed through BookInfoManager.extractBookInfo, not just
-- matching ones. A source's own provider require doubles as its
-- availability check: if the companion plugin isn't installed, the
-- require fails and getProvider returns nil, so no separate
-- "is this plugin loaded" probe is needed here.
-- ---------------------------------------------------------------------------

local SOURCES = {
    getChapterArchiveProvider,
}

local function resolveProvider(path)
    for _, getProvider in ipairs(SOURCES) do
        local provider = getProvider(path)
        if provider then return provider end
    end
end

-- ---------------------------------------------------------------------------
-- BookInfoManager patch
-- ---------------------------------------------------------------------------

function Providers.install()
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    local ok_registry, DocumentRegistry = pcall(require, "document/documentregistry")
    if not (ok_bim and ok_registry)
            or type(BookInfoManager) ~= "table"
            or type(BookInfoManager.extractBookInfo) ~= "function"
            or type(DocumentRegistry) ~= "table"
            or type(DocumentRegistry.getProvider) ~= "function" then
        return false
    end
    if BookInfoManager._simpleui_metadata_providers_patched then
        return true
    end

    local orig_extractBookInfo = BookInfoManager.extractBookInfo
    function BookInfoManager:extractBookInfo(filepath, ...)
        local provider = resolveProvider(filepath)
        if not provider then
            return orig_extractBookInfo(self, filepath, ...)
        end

        local orig_getProvider = DocumentRegistry.getProvider
        DocumentRegistry.getProvider = function(registry, file, ...)
            if file == filepath then return provider end
            return orig_getProvider(registry, file, ...)
        end
        local ok_extract, result = pcall(orig_extractBookInfo, self, filepath, ...)
        DocumentRegistry.getProvider = orig_getProvider
        if not ok_extract then
            logger.warn("simpleui: external metadata extraction failed:", tostring(result))
            error(result, 0)
        end
        return result
    end

    -- Cached rows for a recognized external source are self-healing: if a
    -- row is missing title or authors (e.g. an earlier extraction ran before
    -- this module recognized the file), it is evicted once per session so
    -- the next lookup re-extracts through the redirected provider above
    -- instead of returning incomplete data indefinitely.
    if type(BookInfoManager.deleteBookInfo) == "function" then
        local orig_getBookInfo = BookInfoManager.getBookInfo
        local healed = {}
        function BookInfoManager:getBookInfo(filepath, ...)
            local bookinfo = orig_getBookInfo(self, filepath, ...)
            if bookinfo and not healed[filepath]
                    and (not bookinfo.title or bookinfo.title == ""
                        or not bookinfo.authors or bookinfo.authors == "")
                    and resolveProvider(filepath) then
                healed[filepath] = true
                self:deleteBookInfo(filepath)
                return orig_getBookInfo(self, filepath, ...)
            end
            return bookinfo
        end
    end

    BookInfoManager._simpleui_metadata_providers_patched = true
    return true
end

return Providers
