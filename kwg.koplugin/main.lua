--[[
WireGuard (kwg) for KOReader on rooted Kindles.

Menu: Settings → Network → WireGuard. Turns the tunnel on/off, toggles start at boot,
and edits the config — field by field or as a whole text.

Layout on the device:
  <this plugin>/kwg, kwg-loop.sh    binary + watchdog (shipped with the plugin)
  <this plugin>/*.conf              a config dropped here is imported on the next start
  /var/local/kwg/wg.conf            the active config (not visible over USB)
  /var/local/kwg/autostart          present = start at boot
  /var/local/kwg/kwg.log            tunnel log
  /etc/upstart/kwg.conf             upstart job that runs the watchdog
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local PathChooser = require("ui/widget/pathchooser")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local JOB_FILE = "/etc/upstart/kwg.conf"
local JOB_MARKER = "managed by the KOReader kwg plugin"
local HIDDEN = "<unchanged>" -- stands in for the private key in the text editor

local TEMPLATE = [[
[Interface]
PrivateKey =
Address = 10.0.0.2/32
DNS = 10.0.0.1

[Peer]
PublicKey =
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
]]

-- section, key, label, hint
local FIELDS = {
    { "Interface", "Address", _("Tunnel address"), "10.0.0.2/32" },
    { "Interface", "DNS", _("DNS servers"), "10.0.0.1 (empty = keep the Wi-Fi DNS)" },
    { "Peer", "Endpoint", _("Server endpoint"), "vpn.example.com:51820" },
    { "Peer", "PublicKey", _("Server public key"), "44 characters, ends with =" },
    { "Peer", "AllowedIPs", _("Routed networks (AllowedIPs)"), "0.0.0.0/0 = everything, or 192.168.1.0/24, …" },
    { "Peer", "PersistentKeepalive", _("Keepalive (seconds)"), "25" },
    { "Peer", "PresharedKey", _("Preshared key (optional)"), "empty = none" },
}

local function q(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(path, s)
    local f, err = io.open(path, "w")
    if not f then return false, err end
    f:write(s)
    f:close()
    return true
end

local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

-- Config text helpers: wg-quick INI, keys are case-insensitive, comments start with #.

local function lineKey(line)
    local k, v = line:match("^%s*([%w]+)%s*=%s*(.-)%s*$")
    if k then
        v = v:gsub("%s*#.*$", "")
        return k:lower(), v
    end
end

local function getValue(text, section, key)
    local sec
    for line in (text or ""):gmatch("[^\n]*") do
        local s = line:match("^%s*%[(%w+)%]")
        if s then
            sec = s:lower()
        elseif sec == section:lower() then
            local k, v = lineKey(line)
            if k == key:lower() then return v end
        end
    end
end

-- Sets (or with value "" removes) key in section; adds the line/section when missing.
local function setValue(text, section, key, value)
    local out, sec, done, last_in_sec = {}, nil, false, nil
    for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
        local s = line:match("^%s*%[(%w+)%]")
        if s then
            sec = s:lower()
            table.insert(out, line)
            if sec == section:lower() then last_in_sec = #out end
        else
            local k = lineKey(line)
            if sec == section:lower() and k == key:lower() and not done then
                if value ~= "" then table.insert(out, key .. " = " .. value) end
                done = true
            else
                table.insert(out, line)
            end
            if sec == section:lower() and line:match("%S") then last_in_sec = #out end
        end
    end
    while #out > 0 and out[#out] == "" do table.remove(out) end
    if not done and value ~= "" then
        if last_in_sec then
            table.insert(out, last_in_sec + 1, key .. " = " .. value)
        else
            if #out > 0 then table.insert(out, "") end
            table.insert(out, "[" .. section .. "]")
            table.insert(out, key .. " = " .. value)
        end
    end
    return table.concat(out, "\n") .. "\n"
end

local function hidePrivateKey(text)
    return (text:gsub("([Pp][Rr][Ii][Vv][Aa][Tt][Ee][Kk][Ee][Yy][ \t]*=[ \t]*)[^\n#]*[^%s#]", "%1" .. HIDDEN))
end

local function restorePrivateKey(text, old)
    local real = getValue(old, "Interface", "PrivateKey") or ""
    return (text:gsub("([Pp][Rr][Ii][Vv][Aa][Tt][Ee][Kk][Ee][Yy][ \t]*=[ \t]*)" .. HIDDEN:gsub("%p", "%%%0"), "%1" .. real))
end

local Kwg = WidgetContainer:extend{
    name = "kwg",
    is_doc_only = false,
}

function Kwg:init()
    -- Off a Kindle (e.g. the desktop emulator) nothing is executed: commands are only logged.
    self.dry = not Device:isKindle()
    self.bin = self.path .. "/kwg"
    self.loop = self.path .. "/kwg-loop.sh"
    self.state = self.dry and (DataStorage:getDataDir() .. "/kwg-test") or "/var/local/kwg"
    self.conf = self.state .. "/wg.conf"
    self.log = self.state .. "/kwg.log"
    self.autostart = self.state .. "/autostart"
    self:sh("mkdir -p " .. q(self.state) .. " && chmod 700 " .. q(self.state), true)
    self:importDropped()
    self.ui.menu:registerToMainMenu(self)
end

-- Runs a shell command; returns true on exit code 0. `always` also runs it in dry mode.
function Kwg:sh(cmd, always)
    if self.dry and not always then
        logger.info("kwg (dry run):", cmd)
        return true
    end
    local r = os.execute(cmd)
    return r == 0 or r == true
end

-- Runs a command and returns its output and whether it succeeded.
function Kwg:run(cmd)
    if self.dry then
        logger.info("kwg (dry run):", cmd)
        return "", false
    end
    local p = io.popen(cmd .. " 2>&1; echo \"::$?\"")
    local out = p:read("*a")
    p:close()
    local code = tonumber(out:match("::(%d+)%s*$"))
    return (out:gsub("::%d+%s*$", "")), code == 0
end

function Kwg:notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

-- A *.conf dropped into the plugin folder (USB / scp) becomes the active config and is
-- removed from the USB storage.
function Kwg:importDropped()
    for f in lfs.dir(self.path) do
        if f:match("%.conf$") then
            local src = self.path .. "/" .. f
            local ok, err = self:installConfig(src)
            if ok then
                os.remove(src)
                UIManager:scheduleIn(1, function()
                    self:notify(T(_("WireGuard: imported %1.\nIt has been removed from the plugin folder."), f))
                end)
            else
                UIManager:scheduleIn(1, function()
                    self:notify(T(_("WireGuard: could not import %1:\n%2"), f, err))
                end)
            end
            return
        end
    end
end

-- Imports a config file; only a valid config replaces the active one.
function Kwg:installConfig(src)
    local text = readFile(src)
    if not text then return false, _("cannot read the file") end
    return self:saveConfig(text, true)
end

-- Saves config text (old one kept as wg.conf.bak); returns ok, error and the validation
-- result (nil = valid). With require_valid an invalid config is not saved.
function Kwg:saveConfig(text, require_valid)
    local tmp = self.conf .. ".new"
    local ok, err = writeFile(tmp, text)
    if not ok then return false, err end
    self:sh("chmod 600 " .. q(tmp), true)
    local invalid = self:check(tmp)
    if invalid and require_valid then
        os.remove(tmp)
        return false, invalid
    end
    if exists(self.conf) then os.rename(self.conf, self.conf .. ".bak") end
    os.rename(tmp, self.conf)
    return true, nil, invalid
end

-- nil if the config (default: the active one) is valid, else the error message.
function Kwg:check(path)
    if self.dry then return nil end
    local out, ok = self:run(q(self.bin) .. " check " .. q(path or self.conf))
    if ok then return nil end
    return (out:gsub("^kwg: ", ""):gsub("%s+$", ""))
end

function Kwg:jobRunning()
    if self.dry then return self.dry_running end
    local out = self:run("status kwg")
    return out:match("start/") ~= nil
end

-- Parsed `kwg status`: { state = "up"/"down", address = …, handshake = …, … }
function Kwg:status()
    local st = { state = "down" }
    if self.dry then return st end
    local out = self:run(q(self.bin) .. " status")
    for k, v in out:gmatch("(%w+): ([^\n]*)") do st[k] = v end
    return st
end

function Kwg:statusLine()
    local st = self:status()
    if st.state == "up" then
        return T(_("Tunnel up · %1 · handshake %2"), st.address or "?", st.handshake or "?")
    elseif self:jobRunning() then
        return _("Tunnel starting (waiting for Wi-Fi?)")
    end
    return _("Tunnel off")
end

-- The upstart job; at boot it only runs when the autostart flag exists.
function Kwg:jobText()
    return table.concat({
        "# kwg: WireGuard tunnel watchdog — " .. JOB_MARKER,
        "start on framework_ready",
        "stop on stopping framework",
        "respawn",
        "pre-start script",
        "  if [ -n \"$UPSTART_EVENTS\" ] && [ ! -f " .. self.autostart .. " ]; then stop; exit 0; fi",
        "end script",
        "exec /bin/sh " .. q(self.loop) .. " " .. q(self.conf) .. " " .. q(self.log),
        "",
    }, "\n")
end

function Kwg:ensureJob()
    local want = self:jobText()
    local have = readFile(JOB_FILE)
    if have == want then return true end
    if self.dry then
        logger.info("kwg (dry run): would install", JOB_FILE, "\n" .. want)
        return true
    end
    -- a hand-installed job (README) started at boot: keep that behaviour
    if have and not have:find(JOB_MARKER, 1, true) and have:find("start on") then
        writeFile(self.autostart, "")
    end
    self:sh("chmod +x " .. q(self.bin) .. " " .. q(self.loop))
    if not self:sh("mntroot rw") then return false end
    local ok = writeFile(JOB_FILE, want)
    self:sh("mntroot ro")
    return ok
end

function Kwg:start()
    if not exists(self.conf) then
        self:notify(_("No WireGuard config yet. Import one or create it under 'Config'."))
        return
    end
    local err = self:check()
    if err then
        self:notify(T(_("The config is not valid:\n%1"), err))
        return
    end
    if not self:ensureJob() then
        self:notify(_("Could not install the upstart job (mntroot rw failed)."))
        return
    end
    self.dry_running = true
    self:sh("start kwg")
end

function Kwg:stop()
    self.dry_running = false
    self:sh("stop kwg")
end

function Kwg:restartIfRunning()
    if self:jobRunning() then
        self:stop()
        self:start()
        self:notify(_("Tunnel restarted with the new config."), 3)
    end
end

-- After saving: tell the user whether the config is complete, restart the tunnel if valid.
function Kwg:afterSave(ok, err, invalid)
    if not ok then
        self:notify(T(_("Could not save the config:\n%1"), err))
    elseif invalid then
        self:notify(T(_("Saved, but the config is not complete yet:\n%1"), invalid))
    elseif self:jobRunning() then
        self:restartIfRunning()
    else
        self:notify(_("Config saved."), 2)
    end
end

function Kwg:editField(field, touchmenu)
    local section, key, label, hint = unpack(field)
    local text = readFile(self.conf) or ""
    local dialog
    dialog = InputDialog:new{
        title = label,
        input = getValue(text, section, key) or "",
        input_hint = hint,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(dialog)
                self:afterSave(self:saveConfig(setValue(readFile(self.conf) or TEMPLATE, section, key, v)))
                if touchmenu then touchmenu:updateItems() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- The whole config as text. The private key is shown as <unchanged>; replace it to set a new one.
function Kwg:editText()
    local old = readFile(self.conf)
    local dialog
    dialog = InputDialog:new{
        title = _("WireGuard config"),
        input = old and hidePrivateKey(old) or TEMPLATE,
        description = T(_("The private key is shown as %1 — leave it to keep the current key."), HIDDEN),
        fullscreen = true,
        allow_newline = true,
        cursor_at_end = false,
        add_nav_bar = true,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                local text = restorePrivateKey(dialog:getInputText(), old or "")
                UIManager:close(dialog)
                self:afterSave(self:saveConfig(text))
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Kwg:editPrivateKey()
    local dialog
    dialog = InputDialog:new{
        title = _("Private key"),
        input = "",
        input_hint = _("44 characters, ends with ="),
        text_type = "password",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = dialog:getInputText():gsub("%s+", "")
                UIManager:close(dialog)
                if v == "" then return end
                self:afterSave(self:saveConfig(setValue(readFile(self.conf) or TEMPLATE, "Interface", "PrivateKey", v)))
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Kwg:publicKey()
    if not exists(self.conf) then return nil end
    local out, ok = self:run(q(self.bin) .. " pubkey " .. q(self.conf))
    return ok and out:match("%S+") or nil
end

function Kwg:generateKey()
    UIManager:show(ConfirmBox:new{
        text = _("Generate a new key pair for this Kindle?\n\nThe current private key is replaced. You then have to add the new public key to the server, or the tunnel will not connect."),
        ok_text = _("Generate"),
        ok_callback = function()
            local key, ok = self:run(q(self.bin) .. " genkey")
            key = ok and key:match("%S+")
            if not key then
                self:notify(_("Could not generate a key."))
                return
            end
            self:afterSave(self:saveConfig(setValue(readFile(self.conf) or TEMPLATE, "Interface", "PrivateKey", key)))
            UIManager:scheduleIn(0.5, function() self:showPublicKey() end)
        end,
    })
end

function Kwg:showPublicKey()
    local pub = self:publicKey()
    self:notify(pub and T(_("Public key of this Kindle (add it to the server):\n\n%1"), pub)
        or _("No valid private key in the config yet."))
end

function Kwg:importFile()
    UIManager:show(PathChooser:new{
        select_directory = false,
        select_file = true,
        show_files = true,
        path = "/mnt/us",
        file_filter = function(f) return f:match("%.conf$") end,
        onConfirm = function(path)
            local ok, err, invalid = self:installConfig(path)
            if ok and not invalid and path:sub(1, 8) == "/mnt/us/" then
                UIManager:show(ConfirmBox:new{
                    text = T(_("Imported. Delete %1 from the USB storage? It contains the private key."), path),
                    ok_text = _("Delete"),
                    ok_callback = function() os.remove(path) end,
                })
            end
            self:afterSave(ok, err, invalid)
        end,
    })
end

function Kwg:showLog()
    local text
    if self.dry then
        text = "(dry run)"
    elseif not exists(self.log) then
        text = _("No log yet — it is written once the tunnel has been started from this menu.")
    else
        text = self:run("tail -n 100 " .. q(self.log))
    end
    UIManager:show(TextViewer:new{ title = _("WireGuard log"), text = text ~= "" and text or _("(empty)") })
end

function Kwg:addToMainMenu(menu_items)
    menu_items.kwg = {
        text = _("WireGuard"),
        sorting_hint = "network",
        sub_item_table_func = function() return self:menuItems() end,
    }
end

function Kwg:menuItems()
    local fields = {}
    for _i, field in ipairs(FIELDS) do
        table.insert(fields, {
            text_func = function()
                local v = getValue(readFile(self.conf), field[1], field[2])
                if v and #v > 24 then v = v:sub(1, 22) .. "…" end
                return field[3] .. ": " .. (v and v ~= "" and v or "—")
            end,
            keep_menu_open = true,
            callback = function(touchmenu) self:editField(field, touchmenu) end,
        })
    end
    fields[#fields].separator = true
    table.insert(fields, { text = _("Enter private key"), keep_menu_open = true, callback = function() self:editPrivateKey() end })
    table.insert(fields, { text = _("Generate new key pair"), keep_menu_open = true, callback = function() self:generateKey() end })
    table.insert(fields, { text = _("Show public key"), keep_menu_open = true, callback = function() self:showPublicKey() end })

    return {
        {
            text_func = function() return self:statusLine() end,
            keep_menu_open = true,
            callback = function(touchmenu)
                local st = self:status()
                local lines = {}
                for _i, k in ipairs({ "state", "address", "endpoint", "handshake", "received", "sent" }) do
                    if st[k] then table.insert(lines, k .. ": " .. st[k]) end
                end
                self:notify(table.concat(lines, "\n"))
                touchmenu:updateItems()
            end,
        },
        {
            text = _("Tunnel on"),
            checked_func = function() return self:jobRunning() end,
            keep_menu_open = true,
            callback = function(touchmenu)
                if self:jobRunning() then self:stop() else self:start() end
                -- give the tunnel a moment before the status line is refreshed
                UIManager:scheduleIn(3, function() touchmenu:updateItems() end)
                touchmenu:updateItems()
            end,
        },
        {
            text = _("Start at boot"),
            checked_func = function() return exists(self.autostart) end,
            keep_menu_open = true,
            callback = function()
                if exists(self.autostart) then
                    os.remove(self.autostart)
                elseif self:ensureJob() then
                    writeFile(self.autostart, "")
                else
                    self:notify(_("Could not install the upstart job (mntroot rw failed)."))
                end
            end,
            separator = true,
        },
        { text = _("Settings"), sub_item_table = fields },
        { text = _("Edit config as text"), keep_menu_open = true, callback = function() self:editText() end },
        { text = _("Import config file"), keep_menu_open = true, callback = function() self:importFile() end, separator = true },
        { text = _("Show log"), keep_menu_open = true, callback = function() self:showLog() end },
    }
end

return Kwg
