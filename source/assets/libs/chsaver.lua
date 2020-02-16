ChapterSaver = {}
local Keys = {}
local Order = {}
local Task = nil
local Downloading = {}

---Path to saved chapters folder
local FOLDER = "ux0:data/noboru/chapters/"

local writeFile = System.writeFile
local closeFile = System.closeFile
local deleteFile = System.deleteFile
local openFile = System.openFile
local readFile = System.readFile
local sizeFile = System.sizeFile
local doesFileExist = System.doesFileExist
local doesDirExist = System.doesDirExist
local createDirectory = System.createDirectory
local listDirectory = System.listDirectory
local rem_dir = RemoveDirectory

---@return string
---Creates key for a chapter from it's Manga's `parserID`, `Link` and chapter `Link`
local function get_key(chapter)
    return (chapter.Manga.ParserID .. chapter.Manga.Link):gsub("%p", "") .. "_" .. chapter.Link:gsub("%p", "")
end

ChapterSaver.getKey = get_key
local getFreeSpace = System.getFreeSpace
local notifyied = false
---Updates Cache things
function ChapterSaver.update()
    if #Order == 0 and Task == nil then
        notifyied = false
        return
    end
    if not Task then
        Task = table.remove(Order, 1)
        if Task.Type == "Download" and getFreeSpace("ux0:") < 50 * 1024 * 1024 then
            if not notifyied then
                Notifications.push(Language[Settings.Language].NOTIFICATIONS.NO_SPACE_LEFT)
                notifyied = true
            end
            Downloading[Task.Key] = nil
            Task = nil
            return
        end
        Task.F = coroutine.create(Task.F)
    else
        if coroutine.status(Task.F) ~= "dead" then
            local _, msg, var1, var2 = coroutine.resume(Task.F)
            if _ then
                if Task.Destroy and msg then
                    Notifications.push(string.format(Language[Settings.Language].NOTIFICATIONS.CANCEL_DOWNLOAD, Task.MangaName, Task.ChapterName))
                    Downloading[Task.Key] = nil
                    Task = nil
                elseif msg == "update_count" then
                    Task.page = var1
                    Task.page_count = var2
                end
            else
                Console.error("Unknown error with saved chapters: " .. msg)
                Downloading[Task.Key] = nil
                Task = nil
            end
        else
            if not Task.Fail then
                if Task.Type == "Download" then
                    Notifications.push(string.format(Language[Settings.Language].NOTIFICATIONS.END_DOWNLOAD, Task.MangaName, Task.ChapterName))
                elseif Task.Type == "Import" then
                    Notifications.push("Import completed!")
                end
            end
            Downloading[Task.Key] = nil
            Task = nil
        end
    end
end

local notify = true

---@param chapter table
---Creates task for downloading `chapter`
function ChapterSaver.downloadChapter(chapter)
    local k = get_key(chapter)
    if not doesDirExist(FOLDER .. k) then
        createDirectory(FOLDER .. k)
    end
    Downloading[k] = {
        Type = "Download",
        Key = k,
        MangaName = chapter.Manga.Name,
        ChapterName = chapter.Name,
        F = function()
            local t = {}
            local connection = Threads.netActionUnSafe(Network.isWifiEnabled)
            if connection then
                ParserManager.prepareChapter(chapter, t)
            else
                Notifications.push(Language[Settings.Language].NOTIFICATIONS.NET_PROBLEM)
                Downloading[k] = nil
                Downloading[k].Fail = true
                return
            end
            while ParserManager.check(t) do
                coroutine.yield("update_count", 0, 0)
            end
            local parser = GetParserByID(chapter.Manga.ParserID)
            for i = 1, #t do
                coroutine.yield("update_count", i, #t)
                local result = {}
                parser:loadChapterPage(t[i], result)
                coroutine.yield(false)
                local retry = 0
                while retry < 3 do
                    Threads.insertTask(result, {
                        Type = "FileDownload",
                        Link = result.Link,
                        Path = "chapters/" .. k .. "/" .. i .. ".image"
                    })
                    while Threads.check(result) do
                        coroutine.yield(false)
                    end
                    if doesFileExist("ux0:data/noboru/chapters/" .. k .. "/" .. i .. ".image") then
                        local size = System.getPictureResolution("ux0:data/noboru/chapters/" .. k .. "/" .. i .. ".image")
                        if not size or size <= 0 then
                            Console.error("error loading picture for " .. k .. " " .. i)
                            retry = retry + 1
                            if retry < 3 then
                                Console.error("retrying")
                            end
                        else
                            break
                        end
                    else
                        retry = retry + 1
                    end
                    coroutine.yield(true)
                end
                if retry == 3 then
                    Notifications.push(Language[Settings.Language].NOTIFICATIONS.NET_PROBLEM)
                    rem_dir("ux0:data/noboru/chapters/" .. k)
                    Downloading[k].Fail = true
                    Downloading[k] = nil
                    return
                end
            end
            local fh = openFile(FOLDER .. k .. "/done.txt", FCREATE)
            writeFile(fh, #t, string.len(#t))
            closeFile(fh)
            Keys[k] = true
            ChapterSaver.save()
            Downloading[k] = nil
        end
    }
    Order[#Order + 1] = Downloading[k]
    Notifications.push(string.format(Language[Settings.Language].NOTIFICATIONS.START_DOWNLOAD, chapter.Manga.Name, chapter.Name))
end

local getTime = System.getTime
local getDate = System.getDate
local function cpy_file(source_path, dest_path)
    local fh1 = openFile(source_path, FREAD)
    local fh2 = openFile(dest_path, FCREATE)
    local contentFh1 = readFile(fh1, sizeFile(fh1))
    writeFile(fh2, contentFh1, #contentFh1)
    closeFile(fh1)
    closeFile(fh2)
end

local listZip = System.listZip
local extractFromZip = System.extractFromZip
local rename = System.rename

function ChapterSaver.importManga(path)
    local h, mn, s = getTime()
    local _, d, mo, y = getDate()
    local Manga = CreateManga(path:match(".*/(.*)%..-$") or path:match(".*/(.-)$"), table.concat({h, mn, s, d, mo, y}, "A"), "", "IMPORTED", "local:book")
    Downloading[path] = {
        Type = "Import",
        Key = path,
        MangaName = Manga.Name,
        ChapterName = "Importing"
    }
    local this = Downloading[path]
    this.F = function()
        if doesDirExist(path) then
            local dir = listDirectory(path)
            local new_dir = {}
            local type
            for _, f in ipairs(dir) do
                local new_type
                if f.directory then
                    new_type = "folder"
                elseif (System.getPictureResolution(path.."/"..f.name) or -1) > 0 then
                    new_type = "image"
                elseif f.name:find("%.cbz$") or f.name:find("%.zip$") then
                    new_type = "package"
                elseif not f.name:find("%.txt$") and not f.name:find("%.xml$") then
                    Notifications.push("ERROR: Unknown type of import pattern")
                    Downloading[path].Fail = true
                    Downloading[path] = nil
                    return
                end
                if not type or new_type == type then
                    type = new_type
                    if new_type then
                        new_dir[#new_dir + 1] = f
                    end
                else
                    Notifications.push("ERROR: Unknown type of import pattern")
                    Downloading[path].Fail = true
                    Downloading[path] = nil
                    return
                end
            end
            dir = new_dir
            table.sort(dir, function(a, b) return a.name < b.name end)
            if type == "folder" then
                local cover_loaded = false
                for _, folder in ipairs(dir) do
                    for _, file in ipairs(listDirectory(path.."/"..folder.name)) do
                        if (System.getPictureResolution(path.."/"..folder.name.."/"..file.name) or -1) <= 0 and not file.name:find("%.txt$") and not file.name:find("%.xml$") then
                            Notifications.push("Bad Image found")
                            Downloading[path].Fail = true
                            Downloading[path] = nil
                            return
                        end
                    end
                end
                local Chapters = {}
                Cache.addManga(Manga)
                for _, folder in ipairs(dir) do
                    local Chapter = {
                        Name = folder.name,
                        Link = table.concat({h, mn, s, d, mo, y, _}, "B"),
                        Pages = {},
                        Manga = Manga
                    }
                    local subdir = listDirectory(path.."/"..folder.name)
                    table.sort(subdir, function(a, b) return a.name < b.name end)
                    local img_links = {}
                    for _, f in ipairs(subdir) do
                        if (System.getPictureResolution(path.."/"..folder.name.."/"..f.name) or -1) > 0 then
                            img_links[#img_links + 1] = path.."/"..folder.name.."/"..f.name
                        end
                    end
                    if #img_links > 0 then
                        Chapters[#Chapters + 1] = Chapter
                        if not cover_loaded then
                            cpy_file(img_links[1], "ux0:data/noboru/cache/"..Cache.getKey(Manga).."/cover.image")
                            cover_loaded = true
                        end
                        img_links = table.concat(img_links, "\n")
                        local k = get_key(Chapter)
                        rem_dir(FOLDER..k)
                        createDirectory(FOLDER..k)
                        local fh = openFile(FOLDER .. k .. "/custom.txt", FCREATE)
                        writeFile(fh, img_links, #img_links)
                        closeFile(fh)
                        Keys[k] = true
                    else
                        Notifications.push(Chapter.Name.."\nerror: no supported images found")
                    end
                end
                if #Chapters > 0 then
                    Cache.saveChapters(Manga, Chapters)
                    Database.add(Manga)
                    ChapterSaver.save()
                else
                    Cache.removeManga(Manga)
                    Notifications.push(path.."\nerror: no supported chapters found")
                    Downloading[path].Fail = true
                end
                Downloading[path] = nil
            elseif type == "image" then
                local img_links = {}
                for _, f in ipairs(dir) do
                    img_links[_] = path.."/"..f.name
                end
                local Chapter = {
                    Name = Manga.Name,
                    Link = table.concat({h, mn, s, d, mo, y}, "B"),
                    Pages = {},
                    Manga = Manga
                }
                if #img_links > 0 then
                    Cache.addManga(Manga, {Chapter})
                    cpy_file(img_links[1], "ux0:data/noboru/cache/"..Cache.getKey(Manga).."/cover.image")
                    img_links = table.concat(img_links, "\n")
                    local k = get_key(Chapter)
                    rem_dir(FOLDER..k)
                    createDirectory(FOLDER..k)
                    local fh = openFile(FOLDER .. k .. "/custom.txt", FCREATE)
                    writeFile(fh, img_links, #img_links)
                    closeFile(fh)
                    Keys[k] = true
                    Database.add(Manga)
                    ChapterSaver.save()
                else
                    Notifications.push(path.."\nerror: no supported images found")
                    Downloading[path].Fail = true
                end
                Downloading[path] = nil
            elseif type == "package" then
                local cover_loaded = false
                Cache.addManga(Manga)
                local mk = Cache.getKey(Manga)
                local Chapters = {}
                for _, pack in ipairs(dir) do
                    local Chapter = {
                        Name = pack.name:match("(.*)%..-$"),
                        Link = table.concat({h, mn, s, d, mo, y, _}, "B"),
                        Pages = {},
                        Manga = Manga
                    }
                    local zip_dir = listZip(path.."/"..pack.name) or {}
                    table.sort(zip_dir, function(a, b) return a.name < b.name end)
                    local contains_images = false
                    for _, file in ipairs(zip_dir) do
                        Console.write(file.name)
                        if file.name:find("%.jpeg$") or file.name:find("%.jpg$") or file.name:find("%.png$") or file.name:find("%.bmp$") then
                            if not cover_loaded then
                                extractFromZip(path.."/"..pack.name, file.name, "ux0:data/noboru/cache/"..mk.."/cover.image")
                                cover_loaded = true
                            end
                            contains_images = true
                            break
                        end
                    end
                    if contains_images then
                        Chapters[#Chapters + 1] = Chapter
                        local k = get_key(Chapter)
                        rem_dir(FOLDER..k)
                        createDirectory(FOLDER..k)
                        local fh = openFile(FOLDER .. k .. "/custom.txt", FCREATE)
                        writeFile(fh, path.."/"..pack.name, #(path.."/"..pack.name))
                        closeFile(fh)
                        Keys[k] = true
                    else
                        Notifications.push(path.."/"..pack.name.."\nerror: no supported images found")
                    end
                end
                if #Chapters > 0 then
                    Cache.saveChapters(Manga, Chapters)
                    Database.add(Manga)
                    ChapterSaver.save()
                else
                    Cache.removeManga(Manga)
                    Notifications.push(Manga.Name.."\nerror: no supported chapters found")
                    Downloading[path].Fail = true
                end
                Downloading[path] = nil
            end
        elseif doesFileExist(path) then
            if path:find("%.cbz$") or path:find("%.zip$") then
                Cache.addManga(Manga)
                local mk = Cache.getKey(Manga)
                local Chapter = {
                    Name = path:match(".*/(.*)%..-$"),
                    Link = table.concat({h, mn, s, d, mo, y, _}, "B"),
                    Pages = {},
                    Manga = Manga
                }
                local zip_dir = listZip(path) or {}
                table.sort(zip_dir, function(a, b) return a.name < b.name end)
                local cover_loaded = false
                for _, file in ipairs(zip_dir) do
                    Console.write(file.name)
                    if file.name:find("%.jpeg$") or file.name:find("%.jpg$") or file.name:find("%.png$") or file.name:find("%.bmp$") then
                        extractFromZip(path, file.name, "ux0:data/noboru/cache/"..mk.."/cover.image")
                        cover_loaded = true
                        break
                    end
                end
                if cover_loaded then
                    local k = get_key(Chapter)
                    rem_dir(FOLDER..k)
                    createDirectory(FOLDER..k)
                    local fh = openFile(FOLDER .. k .. "/custom.txt", FCREATE)
                    writeFile(fh, path, #path)
                    closeFile(fh)
                    Keys[k] = true
                    Cache.saveChapters(Manga, {Chapter})
                    Database.add(Manga)
                    ChapterSaver.save()
                else
                    Cache.removeManga(Manga)
                    Notifications(path.."\nerror: no supported images found")
                    Downloading[path].Fail = true
                end
                Downloading[path] = nil
            else
                Notifications(path.."\nerror: this format not supported")
                Downloading[path].Fail = true
                Downloading[path] = nil
            end
        end
    end
    Order[#Order + 1] = this
end

---@return boolean
---Gives info if download is running
function ChapterSaver.is_download_running()
    return Task ~= nil or #Order > 0
end

---@param key string
---Stops task by it's key
local function stop(key)
    if Downloading[key] then
        if Downloading[key] == Task then
            Downloading[key].Destroy = true
        else
            local new_order = {}
            for _, v in ipairs(Order) do
                if v == Downloading[key] then
                    if notify then
                        Notifications.push(string.format(Language[Settings.Language].NOTIFICATIONS.CANCEL_DOWNLOAD, v.MangaName, v.ChapterName))
                    end
                else
                    new_order[#new_order + 1] = v
                end
            end
            Order = new_order
        end
        Downloading[key] = nil
        rem_dir(FOLDER .. key)
    end
end

---@param chapter table
---Stops `chapter` downloading
function ChapterSaver.stop(chapter)
    if chapter then stop(get_key(chapter)) end
end

---@param item table
---Stops `chapter` downloading by List item from `Cache.getDownloadingList` function
function ChapterSaver.stopByListItem(item)
    if item then stop(item.Key) end
end

---@param chapter table
---Deletes saved chapter
function ChapterSaver.delete(chapter)
    local k = get_key(chapter)
    if Keys[k] then
        rem_dir(FOLDER .. k)
        Keys[k] = nil
        ChapterSaver.save()
        Notifications.push(string.format(Language[Settings.Language].NOTIFICATIONS.CHAPTER_REMOVE, k))
    end
end

---@return table
---Returns all active downloadings
function ChapterSaver.getDownloadingList()
    local list = {}
    Order[0] = Task
    for i = Task and 0 or 1, #Order do
        local task = Order[i]
        list[#list + 1] = {
            Manga = task.MangaName,
            Chapter = task.ChapterName,
            page = task.page or 0,
            page_count = task.page_count or 0,
            Key = task.Key
        }
    end
    return list
end

---@param chapter table
---@return boolean
---Gives `true` if chapter is downloaded
function ChapterSaver.check(chapter)
    return Keys[get_key(chapter)] == true or chapter and chapter.FastLoad
end


---@param chapter table
---@return boolean
---Gives `true` if chapter is downloading
function ChapterSaver.is_downloading(chapter)
    return Downloading[get_key(chapter)]
end


---@param str string
---@return table
---Breaks text into lines
local function to_lines(str)
    if str:sub(-1) ~= "\n" then
        str = str .. "\n"
    end
    local lines = {}
    for line in str:gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

---@param chapter table
---@return table
---Gives table with all pathes to chapters images (pages)
function ChapterSaver.getChapter(chapter)
    if chapter.FastLoad then
        local _table_ = {
            Done = true
        }
        local zip = listZip(chapter.Path)
        table.sort(zip, function (a,b)
            return a.name < b.name
        end)
        for i, file in ipairs(zip) do
            if not file.directory and (file.name:find("%.jpg$") or file.name:find("%.png$") or file.name:find("%.jpeg$") or file.name:find("%.bmp$")) then
                _table_[#_table_+1] = {
                    Extract = file.name,
                    Path = chapter.Path:match("/noboru/(.*)$")
                }
            end
        end
        return _table_
    end
    local k = get_key(chapter)
    local _table_ = {
        Done = true
    }
    if Keys[k] then
        if doesFileExist(FOLDER..k.."/custom.txt") then
            local fh_2 = openFile(FOLDER .. k .. "/custom.txt", FREAD)
            local pathes = readFile(fh_2, sizeFile(fh_2))
            closeFile(fh_2)
            local lines = to_lines(pathes)
            if #lines == 1 and (lines[1]:find("%.cbz$") or lines[1]:find("%.zip$")) then
                local zip = listZip(lines[1])
                table.sort(zip, function (a,b)
                    return a.name < b.name
                end)
                for _, file in ipairs(zip) do
                    if not file.directory and (file.name:find("%.jpg$") or file.name:find("%.png$") or file.name:find("%.jpeg$") or file.name:find("%.bmp$")) then
                        _table_[#_table_+1] = {
                            Extract = file.name,
                            Path = lines[1]:match("/noboru/(.*)$")
                        }
                    end
                end
            else
                for _, path in ipairs(lines) do
                    _table_[_] = {
                        Path = path:match("/noboru/(.*)$")
                    }
                end
            end
        else
            local pages = #listDirectory(FOLDER .. k) - 1
            for i = 1, pages do
                _table_[i] = {
                    Path = "chapters/" .. k .. "/" .. i .. ".image"
                }
            end
        end
    end
    return _table_
end

---Saves saved chapters changes
function ChapterSaver.save()
    if doesFileExist("ux0:data/noboru/c.c") then
        deleteFile("ux0:data/noboru/c.c")
    end
    local fh = openFile("ux0:data/noboru/c.c", FCREATE)
    local save_data = table.serialize(Keys, "Keys")
    writeFile(fh, save_data, #save_data)
    closeFile(fh)
end

---Loads saved chapters changes
function ChapterSaver.load()
    Keys = {}
    if doesFileExist("ux0:data/noboru/c.c") then
        local fh = openFile("ux0:data/noboru/c.c", FREAD)
        local suc, keys = pcall(function() return load("local " .. readFile(fh, sizeFile(fh)) .. " return Keys")() end)
        if suc then
            local cnt = 0
            for _, _ in pairs(keys) do
                cnt = cnt + 1
            end
            local cntr = 1
            for k, _ in pairs(keys) do
                coroutine.yield("ChapterSaver: Checking " .. FOLDER .. k, cntr / cnt)
                if doesFileExist(FOLDER .. k .. "/custom.txt") then
                    local fh_2 = openFile(FOLDER .. k .. "/custom.txt", FREAD)
                    local pathes = readFile(fh_2, sizeFile(fh_2))
                    closeFile(fh_2)
                    for _, path in ipairs(to_lines(pathes)) do
                        if not doesFileExist(path) then
                            rem_dir(FOLDER .. k)
                            Notifications.push("here chapters_error\n" .. k)
                            break
                        end
                    end
                    Keys[k] = true
                elseif doesFileExist(FOLDER .. k .. "/done.txt") then
                    local fh_2 = openFile(FOLDER .. k .. "/done.txt", FREAD)
                    local pages = readFile(fh_2, sizeFile(fh_2))
                    closeFile(fh_2)
                    local lDir = listDirectory(FOLDER .. k)
                    if tonumber(pages) == #lDir - 1 then
                        --[[
                        -- This code checks all images in cache, their type (more safer)
                        local count = 0
                        for i = 1, #lDir do
                            local width = System.getPictureResolution(FOLDER .. k .. "/" .. lDir[i].name)
                            if not width or width <= 0 then
                                count = count + 1
                                if count == 2 then
                                    rem_dir("ux0:data/noboru/chapters/" .. k)
                                    Notifications.push("chapters_error_wrong_image\n" .. k)
                                    break
                                end
                            end
                        end
                        if count < 2 then
                            Keys[k] = true
                        end]]
                        Keys[k] = true
                    else
                        rem_dir("ux0:data/noboru/chapters/" .. k)
                        Notifications.push("chapters_error\n" .. k)
                    end
                else
                    rem_dir("ux0:data/noboru/chapters/" .. k)
                    Notifications.push("chapters_error\n" .. k)
                end
                cntr = cntr + 1
            end
            local dir_list = listDirectory("ux0:data/noboru/chapters")
            for _, v in ipairs(dir_list) do
                if not Keys[v.name] and v.directory then
                    rem_dir("ux0:data/noboru/chapters/" .. v.name)
                end
            end
        end
        closeFile(fh)
        ChapterSaver.save()
    end
end

function ChapterSaver.setKey(key)
    Keys[key] = true
    ChapterSaver.save()
end

---Clears all saved chapters
function ChapterSaver.clear()
    notify = false
    for _, v in ipairs(ChapterSaver.getDownloadingList()) do
        ChapterSaver.stopByListItem(v)
    end
    notify = true
    rem_dir("ux0:data/noboru/chapters")
    createDirectory("ux0:data/noboru/chapters")
    Keys = {}
    ChapterSaver.save()
    Notifications.push(Language[Settings.Language].NOTIFICATIONS.CHAPTERS_CLEARED)
end