local M = {}

local defaults = {
  config_path = vim.fn.expand("~/.config/spotify-nvim.json"),
  redirect_uri = "http://127.0.0.1:8888/callback",
  scopes = {
    "user-read-playback-state",
    "user-modify-playback-state",
    "user-read-currently-playing",
    "user-read-recently-played",
    "user-top-read",
    "user-library-modify",
    "user-library-read",
    "playlist-read-private",
    "playlist-read-collaborative",
  },
  status = {
    position = "top-right",
    width = 38,
    refresh_ms = 2000,
    border = "rounded",
  },
}

local cfg = vim.deepcopy(defaults)

-- Persist state globally so :Lazy reload kills orphaned timers / windows
_G.__spotify_nvim_state = _G.__spotify_nvim_state or { status = { win = nil, buf = nil, timer = nil } }
local state = _G.__spotify_nvim_state

-- On module load: kill any timer left over from previous module instance
if state.status.timer then
  pcall(function() state.status.timer:stop(); state.status.timer:close() end)
  state.status.timer = nil
end
if state.status.win and not pcall(vim.api.nvim_win_is_valid, state.status.win) then
  state.status.win = nil
end

-- ============ low-level helpers ============

local function read_config()
  if vim.fn.filereadable(cfg.config_path) == 0 then return {} end
  local ok, data = pcall(vim.fn.json_decode, table.concat(vim.fn.readfile(cfg.config_path), "\n"))
  return ok and data or {}
end

local function write_config(data)
  vim.fn.writefile({ vim.fn.json_encode(data) }, cfg.config_path)
  vim.fn.system({ "chmod", "600", cfg.config_path })
end

local function b64(s)
  return vim.trim(vim.fn.system({ "bash", "-c", "printf '%s' " .. vim.fn.shellescape(s) .. " | base64" }))
end

local function urlencode(s)
  return (tostring(s):gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function osa(script)
  vim.fn.jobstart({ "osascript", "-e", script }, { detach = true })
end

local function osa_capture(script)
  return vim.trim(vim.fn.system({ "osascript", "-e", script }))
end

local function osa_capture_async(script, cb)
  vim.system({ "osascript", "-e", script }, { text = true }, function(res)
    vim.schedule(function() cb(vim.trim(res.stdout or "")) end)
  end)
end

local function curl_async(args, cb)
  vim.system(args, { text = true }, function(res)
    vim.schedule(function() cb(res.stdout or "") end)
  end)
end

-- ============ auth ============

local function refresh_access_token()
  local c = read_config()
  if not c.refresh_token then return nil end
  local auth = b64(c.client_id .. ":" .. c.client_secret)
  local res = vim.fn.system({
    "curl", "-s", "-X", "POST", "https://accounts.spotify.com/api/token",
    "-H", "Authorization: Basic " .. auth,
    "-H", "Content-Type: application/x-www-form-urlencoded",
    "-d", "grant_type=refresh_token&refresh_token=" .. urlencode(c.refresh_token),
  })
  local ok, body = pcall(vim.fn.json_decode, res)
  if not ok or not body.access_token then return nil end
  c.access_token = body.access_token
  c.token_expires_at = os.time() + (body.expires_in or 3600) - 60
  if body.refresh_token then c.refresh_token = body.refresh_token end
  write_config(c)
  return body.access_token
end

local function user_token()
  local c = read_config()
  if c.access_token and c.token_expires_at and os.time() < c.token_expires_at then
    return c.access_token
  end
  if c.refresh_token then return refresh_access_token() end
  return nil
end

-- ============ Web API ============

local function api(method, path, query, body)
  local token = user_token()
  if not token then
    vim.notify("Run :SpotifyAuth first", vim.log.levels.WARN)
    return nil
  end
  local url = "https://api.spotify.com/v1" .. path
  if query then
    local parts = {}
    for k, v in pairs(query) do table.insert(parts, k .. "=" .. urlencode(v)) end
    if #parts > 0 then url = url .. "?" .. table.concat(parts, "&") end
  end
  local args = { "curl", "-s", "-X", method, url, "-H", "Authorization: Bearer " .. token }
  if body then
    table.insert(args, "-H"); table.insert(args, "Content-Type: application/json")
    table.insert(args, "-d"); table.insert(args, vim.fn.json_encode(body))
  end
  table.insert(args, "-w"); table.insert(args, "\n%{http_code}")
  local res = vim.fn.system(args)
  local nl_idx = res:find("\n[^\n]*$") or 1
  local code = tonumber(res:sub(nl_idx + 1)) or 0
  local body_str = res:sub(1, nl_idx - 1)
  if code == 401 then
    refresh_access_token()
    return api(method, path, query, body)
  end
  if code == 204 or body_str == "" then return { ok = code < 400, status = code }, code end
  local ok, parsed = pcall(vim.fn.json_decode, body_str)
  return ok and parsed or nil, code
end

-- ============ auth flow ============

local function random_state()
  math.randomseed(os.time() + os.clock() * 1000000)
  local s = ""
  for _ = 1, 16 do s = s .. string.format("%x", math.random(0, 15)) end
  return s
end

function M.auth()
  local c = read_config()
  if not c.client_id or not c.client_secret then
    vim.notify("client_id/secret missing in " .. cfg.config_path, vim.log.levels.ERROR)
    return
  end
  local st = random_state()
  local server = vim.uv.new_tcp()
  local ok, err = pcall(function()
    server:bind("127.0.0.1", 8888)
    server:listen(16, function(lerr)
      if lerr then return end
      local client = vim.uv.new_tcp()
      server:accept(client)
      client:read_start(function(_, chunk)
        if not chunk then client:close(); return end
        local path = chunk:match("GET ([^ ]+) HTTP")
        local code = path and path:match("code=([^&]+)")
        local resp_state = path and path:match("state=([^& ]+)")
        local html, success = "", false
        if code and resp_state == st then
          html = [[<html><body style="font-family:system-ui;background:#1db954;color:#fff;text-align:center;padding:80px"><h1>✓ Spotify connected</h1><p>Close this tab and return to Neovim.</p></body></html>]]
          success = true
        else
          html = "<html><body><h1>Auth failed</h1></body></html>"
        end
        local resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: " .. #html .. "\r\nConnection: close\r\n\r\n" .. html
        client:write(resp, function()
          client:shutdown(function() client:close() end)
          server:close()
          if success then
            vim.schedule(function()
              local cc = read_config()
              local auth_header = b64(cc.client_id .. ":" .. cc.client_secret)
              local res = vim.fn.system({
                "curl", "-s", "-X", "POST", "https://accounts.spotify.com/api/token",
                "-H", "Authorization: Basic " .. auth_header,
                "-H", "Content-Type: application/x-www-form-urlencoded",
                "-d", "grant_type=authorization_code&code=" .. code .. "&redirect_uri=" .. urlencode(cfg.redirect_uri),
              })
              local pok, body = pcall(vim.fn.json_decode, res)
              if not pok or not body.access_token then
                vim.notify("Token exchange failed", vim.log.levels.ERROR)
                return
              end
              cc.access_token = body.access_token
              cc.refresh_token = body.refresh_token
              cc.token_expires_at = os.time() + (body.expires_in or 3600) - 60
              write_config(cc)
              vim.notify("Spotify auth complete", vim.log.levels.INFO)
            end)
          end
        end)
      end)
    end)
  end)
  if not ok then
    vim.notify("Local server failed: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local url = "https://accounts.spotify.com/authorize?"
    .. "client_id=" .. c.client_id
    .. "&response_type=code"
    .. "&redirect_uri=" .. urlencode(cfg.redirect_uri)
    .. "&scope=" .. urlencode(table.concat(cfg.scopes, " "))
    .. "&state=" .. st
  vim.fn.jobstart({ "open", url }, { detach = true })
  vim.notify("Opened browser. Click Agree to authorize.", vim.log.levels.INFO)
end

function M.logout()
  local c = read_config()
  c.access_token = nil
  c.refresh_token = nil
  c.token_expires_at = nil
  write_config(c)
  vim.notify("Spotify tokens cleared")
end

-- ============ playback ============

function M.playpause()
  local res = api("GET", "/me/player")
  if res and res.is_playing then
    api("PUT", "/me/player/pause")
  else
    api("PUT", "/me/player/play")
  end
end

function M.next() api("POST", "/me/player/next") end
function M.prev() api("POST", "/me/player/previous") end
function M.seek_forward()
  local r = api("GET", "/me/player")
  if not r or not r.progress_ms then return end
  api("PUT", "/me/player/seek", { position_ms = r.progress_ms + 10000 })
end
function M.seek_backward()
  local r = api("GET", "/me/player")
  if not r or not r.progress_ms then return end
  api("PUT", "/me/player/seek", { position_ms = math.max(0, r.progress_ms - 10000) })
end
function M.volume_up() osa('tell application "Spotify" to set sound volume to (sound volume + 10)') end
function M.volume_down() osa('tell application "Spotify" to set sound volume to (sound volume - 10)') end

function M.shuffle_toggle()
  local r = api("GET", "/me/player")
  if not r then return end
  local new = not r.shuffle_state
  api("PUT", "/me/player/shuffle", { state = tostring(new) })
end

function M.repeat_toggle()
  local r = api("GET", "/me/player")
  if not r then return end
  local cycle = { off = "context", context = "track", track = "off" }
  api("PUT", "/me/player/repeat", { state = cycle[r.repeat_state] or "context" })
end

function M.save_current()
  local r = api("GET", "/me/player/currently-playing")
  if not r or not r.item then vim.notify("Nothing playing"); return end
  api("PUT", "/me/tracks", { ids = r.item.id })
  vim.notify("Saved: " .. r.item.name)
end

function M.add_to_queue(uri)
  api("POST", "/me/player/queue", { uri = uri })
  vim.notify("Added to queue")
end

function M.play_uri(uri, context_uri)
  local payload
  if context_uri then
    payload = { context_uri = context_uri, offset = { uri = uri } }
  elseif uri:match("^spotify:track:") then
    payload = { uris = { uri } }
  else
    payload = { context_uri = uri }
  end
  local _, code = api("PUT", "/me/player/play", nil, payload)
  if code == 404 then
    vim.notify("No active device. Open Spotify or use :SpotifyDevices", vim.log.levels.WARN)
  end
end

-- ============ telescope pickers ============

local function tele()
  return {
    pickers = require("telescope.pickers"),
    finders = require("telescope.finders"),
    conf = require("telescope.config").values,
    actions = require("telescope.actions"),
    state = require("telescope.actions.state"),
  }
end

local function track_entry(t)
  local artists = {}
  for _, a in ipairs(t.artists or {}) do table.insert(artists, a.name) end
  return {
    display = string.format("%-40s  %-28s  [%s]",
      (t.name or ""):sub(1, 40),
      table.concat(artists, ", "):sub(1, 28),
      (t.album and t.album.name or ""):sub(1, 28)),
    uri = t.uri,
    name = t.name,
  }
end

local function open_picker(title, items, on_select, extra_mappings)
  local T = tele()
  T.pickers.new({}, {
    prompt_title = title,
    finder = T.finders.new_table({
      results = items,
      entry_maker = function(e) return { value = e, display = e.display, ordinal = e.display } end,
    }),
    sorter = T.conf.generic_sorter({}),
    attach_mappings = function(bufnr, map)
      T.actions.select_default:replace(function()
        local sel = T.state.get_selected_entry()
        T.actions.close(bufnr)
        if sel then on_select(sel.value) end
      end)
      if extra_mappings then
        for _, m in ipairs(extra_mappings) do
          map(m.mode or "i", m.key, function()
            local sel = T.state.get_selected_entry()
            if sel then m.fn(sel.value, bufnr) end
          end)
          map("n", m.key, function()
            local sel = T.state.get_selected_entry()
            if sel then m.fn(sel.value, bufnr) end
          end)
        end
      end
      return true
    end,
  }):find()
end

function M.search(kind)
  kind = kind or "track"
  vim.ui.input({ prompt = "Spotify search (" .. kind .. "): " }, function(query)
    if not query or query == "" then return end
    local res = api("GET", "/search", { q = query, type = kind, limit = 30 })
    if not res then return end
    local list = res[kind .. "s"]
    if not list then return end
    local items = {}
    if kind == "track" then
      for _, t in ipairs(list.items) do table.insert(items, track_entry(t)) end
    elseif kind == "album" then
      for _, a in ipairs(list.items) do
        local artists = {}
        for _, ar in ipairs(a.artists) do table.insert(artists, ar.name) end
        table.insert(items, {
          display = string.format("%-40s  %s", a.name:sub(1, 40), table.concat(artists, ", ")),
          uri = a.uri, name = a.name,
        })
      end
    elseif kind == "artist" then
      for _, a in ipairs(list.items) do
        table.insert(items, {
          display = string.format("%-40s  %d followers", a.name:sub(1, 40), a.followers and a.followers.total or 0),
          uri = a.uri, name = a.name,
        })
      end
    elseif kind == "playlist" then
      for _, p in ipairs(list.items) do
        if p then
          table.insert(items, {
            display = string.format("%-40s  by %s", (p.name or ""):sub(1, 40), p.owner and p.owner.display_name or ""),
            uri = p.uri, name = p.name,
          })
        end
      end
    end
    open_picker("Spotify " .. kind .. ": " .. query, items,
      function(v) M.play_uri(v.uri) end,
      {
        { key = "<C-q>", fn = function(v) M.add_to_queue(v.uri) end },
      })
  end)
end

function M.search_track() M.search("track") end
function M.search_album() M.search("album") end
function M.search_artist() M.search("artist") end
function M.search_playlist() M.search("playlist") end

function M.playlists()
  local res = api("GET", "/me/playlists", { limit = 50 })
  if not res or not res.items then return end
  local items = {}
  for _, p in ipairs(res.items) do
    table.insert(items, {
      display = string.format("%-40s  %d tracks", p.name:sub(1, 40), p.tracks.total),
      uri = p.uri, id = p.id, name = p.name,
    })
  end
  open_picker("Spotify Playlists", items, function(v) M.playlist_tracks(v.id, v.name, v.uri) end)
end

function M.playlist_tracks(playlist_id, playlist_name, playlist_uri)
  local res = api("GET", "/playlists/" .. playlist_id .. "/tracks", { limit = 100 })
  if not res or not res.items then return end
  local items = {}
  for _, item in ipairs(res.items) do
    if item.track then table.insert(items, track_entry(item.track)) end
  end
  open_picker("Playlist: " .. playlist_name, items,
    function(v) M.play_uri(v.uri, playlist_uri) end,
    {
      { key = "<C-q>", fn = function(v) M.add_to_queue(v.uri) end },
    })
end

function M.liked_songs()
  local res = api("GET", "/me/tracks", { limit = 50 })
  if not res or not res.items then return end
  local items = {}
  for _, item in ipairs(res.items) do
    if item.track then table.insert(items, track_entry(item.track)) end
  end
  open_picker("Liked Songs", items,
    function(v) M.play_uri(v.uri) end,
    {
      { key = "<C-q>", fn = function(v) M.add_to_queue(v.uri) end },
    })
end

function M.recently_played()
  local res = api("GET", "/me/player/recently-played", { limit = 30 })
  if not res or not res.items then return end
  local items = {}
  for _, item in ipairs(res.items) do
    if item.track then table.insert(items, track_entry(item.track)) end
  end
  open_picker("Recently Played", items,
    function(v) M.play_uri(v.uri) end,
    {
      { key = "<C-q>", fn = function(v) M.add_to_queue(v.uri) end },
    })
end

function M.new_releases()
  local res = api("GET", "/browse/new-releases", { limit = 50 })
  if not res or not res.albums then return end
  local items = {}
  for _, a in ipairs(res.albums.items) do
    local artists = {}
    for _, ar in ipairs(a.artists) do table.insert(artists, ar.name) end
    table.insert(items, {
      display = string.format("%-40s  %-24s  %s",
        a.name:sub(1, 40),
        table.concat(artists, ", "):sub(1, 24),
        a.release_date or ""),
      uri = a.uri, id = a.id, name = a.name,
    })
  end
  open_picker("New Releases", items, function(v) M.album_tracks(v.id, v.name, v.uri) end)
end

function M.album_tracks(album_id, album_name, album_uri)
  local res = api("GET", "/albums/" .. album_id .. "/tracks", { limit = 50 })
  if not res or not res.items then return end
  local items = {}
  for _, t in ipairs(res.items) do
    t.album = { name = album_name }
    table.insert(items, track_entry(t))
  end
  open_picker("Album: " .. album_name, items,
    function(v) M.play_uri(v.uri, album_uri) end,
    { { key = "<C-q>", fn = function(v) M.add_to_queue(v.uri) end } })
end

function M.queue()
  local res = api("GET", "/me/player/queue")
  if not res then return end
  local items = {}
  if res.currently_playing then
    local e = track_entry(res.currently_playing)
    e.display = "▶ " .. e.display
    table.insert(items, e)
  end
  for i, t in ipairs(res.queue or {}) do
    local e = track_entry(t)
    e.display = string.format("%2d. %s", i, e.display)
    table.insert(items, e)
  end
  if #items == 0 then vim.notify("Queue empty"); return end
  open_picker("Queue (Spotify API has no remove; reorder in app)", items,
    function() end,
    {
      { key = "<C-q>", fn = function(v) M.add_to_queue(v.uri) end },
    })
end

function M.devices()
  local res = api("GET", "/me/player/devices")
  if not res or not res.devices or #res.devices == 0 then
    vim.notify("No devices found"); return
  end
  vim.ui.select(res.devices, {
    prompt = "Transfer to device:",
    format_item = function(d)
      return string.format("%s [%s]%s", d.name, d.type, d.is_active and " ✓" or "")
    end,
  }, function(choice)
    if not choice then return end
    api("PUT", "/me/player", nil, { device_ids = { choice.id }, play = true })
  end)
end

-- ============ status widget ============

local function fmt_time(sec)
  sec = math.floor(sec)
  return string.format("%02d:%02d", math.floor(sec / 60), sec % 60)
end

local function progress_bar(pos, dur, width)
  if dur <= 0 then return string.rep("▱", width) end
  local filled = math.floor((pos / dur) * width)
  if filled > width then filled = width end
  return string.rep("▰", filled) .. string.rep("▱", width - filled)
end

local STATUS_SCRIPT = [[
  tell application "Spotify"
    if it is running then
      set s to player state as string
      set t to name of current track
      set a to artist of current track
      set al to album of current track
      set dur to (duration of current track) / 1000
      set pos to player position
      set vol to sound volume
      return s & "|" & t & "|" & a & "|" & al & "|" & dur & "|" & pos & "|" & vol
    else
      return "off"
    end if
  end tell
]]

local function parse_status(raw)
  if not raw or raw == "off" or raw == "" then return nil end
  local p = vim.split(raw, "|")
  if not p[2] or p[2] == "" then return nil end
  return {
    state = p[1], track = p[2], artist = p[3], album = p[4],
    duration = tonumber(p[5]) or 0,
    position = tonumber(p[6]) or 0,
    volume = tonumber(p[7]) or 0,
    source = "local",
  }
end

local function fetch_local_status_async(cb)
  osa_capture_async(STATUS_SCRIPT, function(raw)
    local st = parse_status(raw)
    if st then cb(st); return end
    -- fallback Web API
    local token = user_token()
    if not token then cb(nil); return end
    curl_async({ "curl", "-s", "https://api.spotify.com/v1/me/player",
      "-H", "Authorization: Bearer " .. token }, function(body)
      local ok, r = pcall(vim.fn.json_decode, body)
      if not ok or not r or not r.item then cb(nil); return end
      local artists = {}
      for _, a in ipairs(r.item.artists or {}) do table.insert(artists, a.name) end
      cb({
        state = r.is_playing and "playing" or "paused",
        track = r.item.name or "",
        artist = table.concat(artists, ", "),
        album = (r.item.album and r.item.album.name) or "",
        duration = (r.item.duration_ms or 0) / 1000,
        position = (r.progress_ms or 0) / 1000,
        volume = (r.device and r.device.volume_percent) or 0,
        source = "remote",
      })
    end)
  end)
end

local function fetch_local_status()
  local script = [[
    tell application "Spotify"
      if it is running then
        set s to player state as string
        set t to name of current track
        set a to artist of current track
        set al to album of current track
        set dur to (duration of current track) / 1000
        set pos to player position
        set vol to sound volume
        return s & "|" & t & "|" & a & "|" & al & "|" & dur & "|" & pos & "|" & vol
      else
        return "off"
      end if
    end tell
  ]]
  local raw = osa_capture(script)
  if raw and raw ~= "off" and raw ~= "" then
    local p = vim.split(raw, "|")
    if p[2] and p[2] ~= "" then
      return {
        state = p[1], track = p[2], artist = p[3], album = p[4],
        duration = tonumber(p[5]) or 0,
        position = tonumber(p[6]) or 0,
        volume = tonumber(p[7]) or 0,
        source = "local",
      }
    end
  end
  -- fallback: Web API (works when playing on phone/web/other device)
  local r = api("GET", "/me/player")
  if not r or not r.item then return nil end
  local artists = {}
  for _, a in ipairs(r.item.artists or {}) do table.insert(artists, a.name) end
  return {
    state = r.is_playing and "playing" or "paused",
    track = r.item.name or "",
    artist = table.concat(artists, ", "),
    album = (r.item.album and r.item.album.name) or "",
    duration = (r.item.duration_ms or 0) / 1000,
    position = (r.progress_ms or 0) / 1000,
    volume = (r.device and r.device.volume_percent) or 0,
    source = "remote",
  }
end

local function pad_display(s, n)
  local w = vim.fn.strdisplaywidth(s)
  if w >= n then return s end
  return s .. string.rep(" ", n - w)
end

local function truncate(s, n)
  if vim.fn.strdisplaywidth(s) <= n then return s end
  return s:sub(1, n - 1) .. "…"
end

local remote_cache = { data = {}, fetched_at = 0 }
local function get_remote_state()
  if os.time() - remote_cache.fetched_at < 5 then return remote_cache.data end
  local r = api("GET", "/me/player")
  if r then
    remote_cache.data = { shuffle = r.shuffle_state, repeat_mode = r.repeat_state }
    remote_cache.fetched_at = os.time()
  end
  return remote_cache.data
end

local function get_remote_state_async(cb)
  if os.time() - remote_cache.fetched_at < 5 then cb(remote_cache.data); return end
  local token = user_token()
  if not token then cb({}); return end
  curl_async({ "curl", "-s", "https://api.spotify.com/v1/me/player",
    "-H", "Authorization: Bearer " .. token }, function(body)
    local ok, r = pcall(vim.fn.json_decode, body)
    if ok and r then
      remote_cache.data = { shuffle = r.shuffle_state, repeat_mode = r.repeat_state }
      remote_cache.fetched_at = os.time()
    end
    cb(remote_cache.data)
  end)
end

local BUTTONS = {}

local function render(st, remote)
  local W = cfg.status.width
  local inner = W - 4
  local play_icon = st.state == "playing" and "⏸ " or "▶ "
  local bar = progress_bar(st.position, st.duration, inner - 2)
  local time = fmt_time(st.position) .. " / " .. fmt_time(st.duration)
  local sh = remote.shuffle and "🔀" or "⇄"
  local rp = remote.repeat_mode == "off" and "↻" or (remote.repeat_mode == "track" and "🔂" or "🔁")
  local btn_line = string.format("  ⏮    %s   ⏭     ♥   %s   %s  ", play_icon, sh, rp)

  -- track click positions (0-indexed cols) within btn_line
  local lines = {
    "",
    "  " .. pad_display(truncate(st.track, inner), inner),
    "  " .. pad_display(truncate(st.artist .. " · " .. st.album, inner), inner),
    "",
    "  " .. bar,
    "  " .. pad_display(time, inner),
    "",
    btn_line,
    "",
  }
  BUTTONS = {
    { line = 8, col_lo = 2,  col_hi = 5,  action = "prev" },
    { line = 8, col_lo = 8,  col_hi = 12, action = "playpause" },
    { line = 8, col_lo = 15, col_hi = 18, action = "next" },
    { line = 8, col_lo = 23, col_hi = 25, action = "save" },
    { line = 8, col_lo = 28, col_hi = 30, action = "shuffle" },
    { line = 8, col_lo = 33, col_hi = 35, action = "repeat" },
  }
  return lines, W
end

local function close_status()
  if state.status.timer then
    state.status.timer:stop(); state.status.timer:close(); state.status.timer = nil
  end
  if state.status.win and vim.api.nvim_win_is_valid(state.status.win) then
    vim.api.nvim_win_close(state.status.win, true)
  end
  state.status.win = nil
  state.status.buf = nil
end

local function handle_click()
  local pos = vim.fn.getmousepos()
  if not state.status.win or pos.winid ~= state.status.win then return end
  for _, b in ipairs(BUTTONS) do
    if pos.line == b.line and pos.column >= b.col_lo and pos.column <= b.col_hi then
      if b.action == "playpause" then M.playpause()
      elseif b.action == "next" then M.next()
      elseif b.action == "prev" then M.prev()
      elseif b.action == "save" then M.save_current()
      elseif b.action == "shuffle" then M.shuffle_toggle()
      elseif b.action == "repeat" then M.repeat_toggle()
      end
      return
    end
  end
end

local function setup_buf_keymaps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", close_status, opts)
  vim.keymap.set("n", "<Esc>", close_status, opts)
  vim.keymap.set("n", "p", M.playpause, opts)
  vim.keymap.set("n", "n", M.next, opts)
  vim.keymap.set("n", "b", M.prev, opts)
  vim.keymap.set("n", "f", M.save_current, opts)
  vim.keymap.set("n", "x", M.shuffle_toggle, opts)
  vim.keymap.set("n", "r", M.repeat_toggle, opts)
  vim.keymap.set("n", "<LeftMouse>", handle_click, opts)
  vim.keymap.set("n", "<2-LeftMouse>", handle_click, opts)
end

function M.toggle_status()
  if state.status.win and vim.api.nvim_win_is_valid(state.status.win) then
    close_status(); return
  end
  -- belt-and-suspenders: kill any leftover timer before starting fresh
  if state.status.timer then
    pcall(function() state.status.timer:stop(); state.status.timer:close() end)
    state.status.timer = nil
  end
  local st = fetch_local_status()
  if not st then vim.notify("Spotify not running"); return end
  local remote = get_remote_state()
  local lines, W = render(st, remote)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "spotifystatus"

  local anchor_row, anchor_col, anchor
  if cfg.status.position == "top-right" then
    anchor_row = 1; anchor_col = vim.o.columns - 2; anchor = "NE"
  elseif cfg.status.position == "top-left" then
    anchor_row = 1; anchor_col = 2; anchor = "NW"
  elseif cfg.status.position == "bottom-left" then
    anchor_row = vim.o.lines - 2; anchor_col = 2; anchor = "SW"
  else
    anchor_row = vim.o.lines - 2; anchor_col = vim.o.columns - 2; anchor = "SE"
  end

  state.status.win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    anchor = anchor,
    row = anchor_row,
    col = anchor_col,
    width = W,
    height = #lines,
    style = "minimal",
    border = cfg.status.border,
    focusable = true,
    noautocmd = true,
    title = " ♫ Spotify ",
    title_pos = "center",
    zindex = 60,
  })
  state.status.buf = buf
  vim.api.nvim_set_option_value("winhl", "Normal:NormalFloat,FloatBorder:FloatBorder,FloatTitle:Special", { win = state.status.win })
  vim.api.nvim_set_option_value("cursorline", false, { win = state.status.win })

  setup_buf_keymaps(buf)

  state.status.timer = vim.uv.new_timer()
  state.status.timer:start(cfg.status.refresh_ms, cfg.status.refresh_ms, vim.schedule_wrap(function()
    if not state.status.win or not vim.api.nvim_win_is_valid(state.status.win) then
      close_status(); return
    end
    fetch_local_status_async(function(cur)
      if not cur then return end
      if not state.status.win or not vim.api.nvim_win_is_valid(state.status.win) then return end
      get_remote_state_async(function(r)
        if not state.status.win or not vim.api.nvim_win_is_valid(state.status.win) then return end
        local new_lines = render(cur, r or {})
        vim.bo[buf].modifiable = true
        pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, new_lines)
        vim.bo[buf].modifiable = false
      end)
    end)
  end))
end

-- ============ public lualine helper ============

function M.statusline()
  local st = fetch_local_status()
  if not st then return "" end
  local icon = st.state == "playing" and "♫" or "■"
  return string.format("%s %s — %s", icon, truncate(st.track, 24), truncate(st.artist, 18))
end

-- ============ setup ============

function M.setup(opts)
  cfg = vim.tbl_deep_extend("force", defaults, opts or {})
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("SpotifyNvimCleanup", { clear = true }),
  callback = function()
    if state.status.timer then
      pcall(function() state.status.timer:stop(); state.status.timer:close() end)
      state.status.timer = nil
    end
  end,
})

return M
