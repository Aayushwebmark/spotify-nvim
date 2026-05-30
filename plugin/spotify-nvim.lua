if vim.g.loaded_spotify_nvim then return end
vim.g.loaded_spotify_nvim = 1

local function lazy(name)
  return function() require("spotify-nvim")[name]() end
end

local commands = {
  SpotifyAuth = "auth",
  SpotifyLogout = "logout",
  SpotifyPlayPause = "playpause",
  SpotifyNext = "next",
  SpotifyPrev = "prev",
  SpotifySeekForward = "seek_forward",
  SpotifySeekBackward = "seek_backward",
  SpotifyVolumeUp = "volume_up",
  SpotifyVolumeDown = "volume_down",
  SpotifyShuffle = "shuffle_toggle",
  SpotifyRepeat = "repeat_toggle",
  SpotifySave = "save_current",
  SpotifyStatus = "toggle_status",
  SpotifySearch = "search_track",
  SpotifySearchAlbum = "search_album",
  SpotifySearchArtist = "search_artist",
  SpotifySearchPlaylist = "search_playlist",
  SpotifyPlaylists = "playlists",
  SpotifyLiked = "liked_songs",
  SpotifyRecent = "recently_played",
  SpotifyTop = "top_tracks",
  SpotifyQueue = "queue",
  SpotifyDevices = "devices",
}

for cmd, fn in pairs(commands) do
  vim.api.nvim_create_user_command(cmd, lazy(fn), {})
end
