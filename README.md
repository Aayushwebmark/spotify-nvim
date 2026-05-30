# spotify-nvim

Control Spotify from Neovim. macOS-first (uses AppleScript + Spotify Web API).

## Features

- Full playback control (play/pause, next, prev, seek, volume, shuffle, repeat)
- Search tracks / albums / artists / playlists (telescope picker)
- Browse playlists → drill into tracks → play in playlist context
- Liked Songs, Recently Played, Top Tracks
- Queue view, add to queue (Spotify API has no public "remove from queue")
- Device picker (transfer playback)
- Pinned status widget with progress bar + clickable buttons
- Lualine helper (`statusline()`)
- OAuth: tokens persisted, auto-refresh

## Requirements

- Neovim ≥ 0.10 (uses `vim.uv`)
- macOS (AppleScript for local control; cross-platform via Web API only would need work)
- `nvim-telescope/telescope.nvim`
- `curl`
- Spotify Premium (required by Spotify Web API for playback control)

## Setup

1. Create app at https://developer.spotify.com/dashboard
2. Add redirect URI `http://127.0.0.1:8888/callback`
3. Save Client ID + Secret to `~/.config/spotify-nvim.json`:

```json
{ "client_id": "...", "client_secret": "..." }
```

4. Install via lazy.nvim:

```lua
{
  "Aayushwebmark/spotify-nvim",
  dependencies = { "nvim-telescope/telescope.nvim" },
  cmd = { "SpotifyAuth", "SpotifyStatus", "SpotifySearch", "SpotifyPlaylists" },
  keys = {
    { "<leader>mm", "<cmd>SpotifyStatus<cr>",    desc = "Spotify status" },
    { "<leader>mp", "<cmd>SpotifyPlayPause<cr>", desc = "Play/pause" },
    { "<leader>mn", "<cmd>SpotifyNext<cr>",      desc = "Next" },
    { "<leader>mb", "<cmd>SpotifyPrev<cr>",      desc = "Prev" },
    { "<leader>ms", "<cmd>SpotifySearch<cr>",    desc = "Search tracks" },
    { "<leader>ml", "<cmd>SpotifyPlaylists<cr>", desc = "Playlists" },
    { "<leader>mq", "<cmd>SpotifyQueue<cr>",     desc = "Queue" },
    { "<leader>mf", "<cmd>SpotifySave<cr>",      desc = "Save current" },
    { "<leader>mx", "<cmd>SpotifyShuffle<cr>",   desc = "Shuffle" },
    { "<leader>mr", "<cmd>SpotifyRepeat<cr>",    desc = "Repeat" },
    { "<leader>md", "<cmd>SpotifyDevices<cr>",   desc = "Devices" },
    { "<leader>mL", "<cmd>SpotifyLiked<cr>",     desc = "Liked songs" },
    { "<leader>mH", "<cmd>SpotifyRecent<cr>",    desc = "Recently played" },
    { "<leader>mN", "<cmd>SpotifyNewReleases<cr>", desc = "New releases" },
  },
  opts = {
    status = { position = "top-right" },
  },
}
```

5. Run `:SpotifyAuth` → browser opens → Allow → done

## Commands

| Command | What |
|---|---|
| `:SpotifyAuth` | OAuth flow (first-time) |
| `:SpotifyLogout` | Clear tokens |
| `:SpotifyStatus` | Toggle status widget |
| `:SpotifyPlayPause` | Play/pause |
| `:SpotifyNext` / `:SpotifyPrev` | Skip |
| `:SpotifySeekForward` / `:SpotifySeekBackward` | ±10s |
| `:SpotifyVolumeUp` / `:SpotifyVolumeDown` | ±10% |
| `:SpotifyShuffle` / `:SpotifyRepeat` | Toggle |
| `:SpotifySave` | Save current track to library |
| `:SpotifySearch` | Search tracks |
| `:SpotifySearchAlbum` / `:SpotifySearchArtist` / `:SpotifySearchPlaylist` | Other searches |
| `:SpotifyPlaylists` | Your playlists → drill into tracks |
| `:SpotifyLiked` | Liked songs |
| `:SpotifyRecent` | Recently played |
| `:SpotifyNewReleases` | Browse new album releases → drill into tracks |
| `:SpotifyQueue` | Queue view |
| `:SpotifyDevices` | Transfer playback |

## Picker shortcuts

- `<CR>` — play
- `<C-q>` — add to queue (in track pickers)

## Status widget

- Pinned (toggle with `:SpotifyStatus`)
- Clickable buttons (when focused): `⏮ ⏯ ⏭  ♥ 🔀 🔁`
- Buffer keymaps: `p` play/pause, `n` next, `b` prev, `f` favorite, `x` shuffle, `r` repeat, `q` close

## Lualine

```lua
require("lualine").setup({
  sections = {
    lualine_x = { function() return require("spotify-nvim").statusline() end },
  },
})
```

## Limitations

- Spotify Web API has no public "remove from queue" endpoint
- macOS only for local AppleScript control (skip status widget on Linux/Windows; remote control still works)
- Free Spotify accounts cannot use playback control endpoints

## License

MIT
