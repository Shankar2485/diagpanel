📦 DiagPanel — A Compact Real-Time Diagnostic Panel for Neovim

A minimal, fast, non-intrusive floating diagnostics panel that shows all LSP diagnostics in the top-right corner, updating intelligently without flickering or distracting the user.


🚀 Features

📌 Always-visible diagnostics panel in the top-right corner

🧙 Custom glyphs/emojis or ASCII symbols

✏️ Live typing mode (auto-hide INFO/HINT during Insert mode)

🔕 Optional severity threshold

🚫 No popup flickering

🔁 Auto-refresh on DiagnosticChanged, BufEnter, CursorHold

⚡ Lightweight — no dependencies, pure Lua


📦 Installation
Lazy.nvim 

```
{
    "Shankar2485/diagpanel",
    config = function()
        require("diagpanel").setup({
            -- your custom config here
        })
    end,
}

```

⚙️ Configuration

All options are optional:

```
require("diagpanel").setup({
    use_ascii = false,
    width_fraction = 0.45,
    height_fraction = 0.25,
    max_lines_min = 3,
    max_msg_len = 80,
    winblend = 45,
    border = "rounded",
    zindex = 300,

    glyphs = {
        ERROR = "⛔",
        WARN  = "🧙",
        INFO  = "🔮",
        HINT  = "💡",
    },

    show_on_bufenter = true,
    show_on_diag_changed = true,
    show_on_cursorhold = true,

    live_typing = false,        -- hide INFO/HINT during Insert
    severity_threshold = nil,   -- use (vim.diagnostic.severity.WARN) to hide INFO/HINT always

    keymap = "<Leader>p",       -- toggle panel
})

```
-------------------------------------------------------------------------------------------------------

🛠️ Severity Threshold

Example:
```
severity_threshold = vim.diagnostic.severity.WARN

```
This hides Info/Hint completely.

--------------------------------------------------------------------------------------------------------

Global toggle:

```
<leader>p  (configurable)
```
--------------------------------------------------------------------------------------------------------

🔧 Live Typing

If live_typing = true:

* Insert mode → panel shows only ERROR/WARN

* Normal mode → panel shows all diagnostics

No flicker, smooth updates.


















