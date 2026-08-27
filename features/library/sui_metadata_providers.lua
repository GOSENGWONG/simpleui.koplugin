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
-- Chapter archives (Rakuyomi CBZ) ship a ComicInfo.xml entry. On e-readers
-- the companion CbzDocument provider can read it via an external binary;
-- on Android that binary cannot run from noexec storage. This module
-- therefore reads ComicInfo.xml from the ZIP itself in pure Lua and
-- injects the result into CbzDocument.getDocumentProps, so metadata
-- extraction works on every platform without depending on the binary.
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

-- True when path is the directory itself or any file/subdir under it.
local function pathIsUnder(path, directory)
    path = normalizePath(path)
    directory = normalizePath(directory)
    if not (path and directory) then return false end
    if path == directory then return true end
    local dir_prefix = directory
    if dir_prefix:sub(-1) ~= "/" then dir_prefix = dir_prefix .. "/" end
    return path:sub(1, #dir_prefix) == dir_prefix
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

-- ---------------------------------------------------------------------------
-- Pure-Lua ZIP helpers (no external binary)
-- ---------------------------------------------------------------------------

local function u16(data, i)
    return (data:byte(i) or 0) + (data:byte(i + 1) or 0) * 256
end

local function u32(data, i)
    return (data:byte(i) or 0)
        + (data:byte(i + 1) or 0) * 256
        + (data:byte(i + 2) or 0) * 65536
        + (data:byte(i + 3) or 0) * 16777216
end

-- Raw DEFLATE inflate via zlib (ZIP method 8). windowBits = -15 selects
-- raw deflate without a zlib/gzip wrapper — required for ZIP payloads.
local _raw_inflate
local function rawInflate(compressed, uncompressed_size)
    if type(compressed) ~= "string" or compressed == "" then return nil end
    if _raw_inflate == false then return nil end
    if _raw_inflate == nil then
        local ok_ffi, ffi = pcall(require, "ffi")
        if not ok_ffi then
            _raw_inflate = false
            return nil
        end
        pcall(function()
            ffi.cdef[[
                typedef struct z_stream_s {
                    const unsigned char *next_in;
                    unsigned int avail_in;
                    unsigned long total_in;
                    unsigned char *next_out;
                    unsigned int avail_out;
                    unsigned long total_out;
                    const char *msg;
                    void *state;
                    void *zalloc;
                    void *zfree;
                    void *opaque;
                    int data_type;
                    unsigned long adler;
                    unsigned long reserved;
                } z_stream;
                int inflateInit2_(z_stream *strm, int windowBits,
                                  const char *version, int stream_size);
                int inflate(z_stream *strm, int flush);
                int inflateEnd(z_stream *strm);
            ]]
        end)
        local libz
        local ok_lib = pcall(function()
            if ffi.loadlib then
                libz = ffi.loadlib("z", 1)
            else
                libz = ffi.load("z")
            end
        end)
        if not ok_lib or not libz or not libz.inflateInit2_ then
            _raw_inflate = false
            return nil
        end
        _raw_inflate = function(data, out_len)
            out_len = math.max(out_len or (#data * 4), 64)
            local stream = ffi.new("z_stream")
            -- Version string is only checked for ABI compatibility; the
            -- stream_size argument is what actually matters.
            local init = libz.inflateInit2_(stream, -15, "1.2.0", ffi.sizeof(stream))
            if init ~= 0 then return nil end
            local out = ffi.new("unsigned char[?]", out_len)
            stream.next_in = ffi.cast("const unsigned char *", data)
            stream.avail_in = #data
            stream.next_out = out
            stream.avail_out = out_len
            local res = libz.inflate(stream, 4) -- Z_FINISH
            libz.inflateEnd(stream)
            -- Z_STREAM_END (1) or Z_OK (0) with full output are both fine.
            if res ~= 1 and res ~= 0 then return nil end
            local produced = tonumber(stream.total_out) or 0
            if produced <= 0 then return nil end
            return ffi.string(out, produced)
        end
    end
    return _raw_inflate(compressed, uncompressed_size)
end

-- Reads a single entry from a ZIP/CBZ archive. Supports store (0) and
-- deflate (8). Returns the entry bytes or nil.
local function readZipEntry(path, entry_name)
    if type(path) ~= "string" or type(entry_name) ~= "string" then return nil end
    local file = io.open(path, "rb")
    if not file then return nil end

    local size = file:seek("end")
    if not size or size < 22 then
        file:close()
        return nil
    end

    -- Locate end-of-central-directory record (last 64 KiB + 22 bytes).
    local tail_len = math.min(size, 65535 + 22)
    file:seek("set", size - tail_len)
    local tail = file:read(tail_len)
    if not tail then
        file:close()
        return nil
    end

    local eocd
    for pos = #tail - 21, 1, -1 do
        if tail:sub(pos, pos + 3) == "PK\005\006" then
            eocd = pos
            break
        end
    end
    if not eocd then
        file:close()
        return nil
    end

    local cd_size   = u32(tail, eocd + 12)
    local cd_offset = u32(tail, eocd + 16)
    if cd_size == 0 or cd_offset + cd_size > size then
        file:close()
        return nil
    end

    file:seek("set", cd_offset)
    local cd = file:read(cd_size)
    if not cd or #cd < cd_size then
        file:close()
        return nil
    end

    -- Scan central directory for the requested entry (case-insensitive).
    local want = entry_name:lower()
    local i = 1
    local local_offset, comp_method, comp_size, uncomp_size
    while i + 46 <= #cd + 1 do
        if cd:sub(i, i + 3) ~= "PK\001\002" then break end
        local method   = u16(cd, i + 10)
        local csize    = u32(cd, i + 20)
        local usize    = u32(cd, i + 24)
        local name_len = u16(cd, i + 28)
        local extra_len = u16(cd, i + 30)
        local comment_len = u16(cd, i + 32)
        local loc_off  = u32(cd, i + 42)
        local name = cd:sub(i + 46, i + 45 + name_len)
        if name:lower() == want then
            local_offset = loc_off
            comp_method  = method
            comp_size    = csize
            uncomp_size  = usize
            break
        end
        i = i + 46 + name_len + extra_len + comment_len
    end
    if not local_offset then
        file:close()
        return nil
    end

    -- Local file header → payload.
    file:seek("set", local_offset)
    local lfh = file:read(30)
    if not lfh or #lfh < 30 or lfh:sub(1, 4) ~= "PK\003\004" then
        file:close()
        return nil
    end
    local l_name_len  = u16(lfh, 27)
    local l_extra_len = u16(lfh, 29)
    -- Skip name + extra; method/sizes in the local header can be zero when
    -- data descriptors are used, so prefer the central-directory values.
    file:seek("set", local_offset + 30 + l_name_len + l_extra_len)
    local payload = file:read(comp_size)
    file:close()
    if not payload or #payload < comp_size then return nil end

    if comp_method == 0 then
        return payload
    elseif comp_method == 8 then
        return rawInflate(payload, uncomp_size)
    end
    return nil
end

-- Reads the trailing ZIP comment (used only for origin-id recognition).
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
            local comment_len = u16(data, pos + 20)
            if pos + 21 + comment_len == read_size and comment_len > 0 then
                return data:sub(pos + 22, pos + 21 + comment_len)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- ComicInfo.xml → KOReader document props
-- ---------------------------------------------------------------------------

local function xmlText(xml, tag)
    -- Matches <Tag>value</Tag> or <Tag ...>value</Tag>; skips empty/self-closing.
    local pattern = "<" .. tag .. "%s*[^>]*>(.-)</" .. tag .. "%s*>"
    local value = xml:match(pattern)
    if not value then return nil end
    -- Strip nested tags if any, decode a few common entities.
    value = value:gsub("<.->", "")
    value = value
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&amp;", "&")
        :gsub("&quot;", '"')
        :gsub("&apos;", "'")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    if value == "" then return nil end
    return value
end

-- Maps ComicInfo.xml fields to the shape CbzDocument/_parseMetadata produces
-- (and BookInfoManager expects), including the singular "author"/"notes"
-- keys that the existing field patch renames to authors/description.
local function parseComicInfoXml(xml)
    if type(xml) ~= "string" or xml == "" then return nil end

    local title    = xmlText(xml, "Title")
    local series   = xmlText(xml, "Series")
    local number   = xmlText(xml, "Number")
    local summary  = xmlText(xml, "Summary")
    local language = xmlText(xml, "LanguageISO")
    local genre    = xmlText(xml, "Genre")
    local publisher = xmlText(xml, "Publisher")
    local year_s   = xmlText(xml, "Year")
    local rating_s = xmlText(xml, "CommunityRating")

    local authors = {}
    local function addAuthor(v)
        if v and v ~= "" then
            for _, existing in ipairs(authors) do
                if existing == v then return end
            end
            authors[#authors + 1] = v
        end
    end
    addAuthor(xmlText(xml, "Writer"))
    addAuthor(xmlText(xml, "Penciller"))
    addAuthor(xmlText(xml, "Inker"))

    local info = {}
    if title then info.title = title end
    if series then info.series = series end
    if number then info.series_index = tonumber(number) or number end
    if publisher then info.publisher = publisher end
    if language then info.language = language end
    if genre then info.keywords = genre end
    if summary then
        info.notes = summary
        info.description = summary
    end
    if #authors > 0 then
        local joined = table.concat(authors, " & ")
        info.author = joined
        info.authors = joined
    end
    if year_s then
        local y = tonumber(year_s)
        if y and y > 0 then info.publication_year = y end
    end
    if rating_s then
        local r = tonumber(rating_s)
        if r and r >= 0 then info.rating = r end
    end

    if not next(info) then return nil end
    return info
end

local comicinfo_cache = {} -- path → { mtime, size, props|false }

local function readComicInfoProps(path)
    if type(path) ~= "string" then return nil end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local size, mtime = 0, 0
    if ok_lfs and lfs then
        size = lfs.attributes(path, "size") or 0
        mtime = lfs.attributes(path, "modification") or 0
    end
    local cached = comicinfo_cache[path]
    if cached and cached.size == size and cached.mtime == mtime then
        return cached.props or nil
    end

    local xml = readZipEntry(path, "ComicInfo.xml")
    local props = xml and parseComicInfoXml(xml) or nil
    comicinfo_cache[path] = { size = size, mtime = mtime, props = props or false }
    return props
end

-- ---------------------------------------------------------------------------
-- Recognition: storage path or origin-id ZIP comment
-- ---------------------------------------------------------------------------

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
    if path:lower():sub(-4) ~= ".cbz" then return false end
    local storage = getChapterStoragePath()
    return pathIsUnder(path, storage) or hasOriginMetadata(path)
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

    -- Patch once: prefer pure-Lua ComicInfo.xml, then fall back to the
    -- provider's own binary/server path. Also normalise author/notes keys
    -- to the plural forms BookInfoManager stores.
    if not CbzDocument._simpleui_authors_field_patched then
        CbzDocument._simpleui_authors_field_patched = true
        local orig_getDocumentProps = CbzDocument.getDocumentProps
        function CbzDocument:getDocumentProps(...)
            local props = orig_getDocumentProps(self, ...)
            if type(props) ~= "table" then props = {} end

            -- Fill gaps from ComicInfo.xml without depending on the
            -- external cbz_metadata_reader binary (unusable on Android).
            local comic = readComicInfoProps(self.file)
            if comic then
                for key, value in pairs(comic) do
                    if value ~= nil and value ~= ""
                            and (props[key] == nil or props[key] == "") then
                        props[key] = value
                    end
                end
            end

            if (not props.authors or props.authors == "") and props.author then
                props.authors = props.author
            end
            if (not props.description or props.description == "") and props.notes then
                props.description = props.notes
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
