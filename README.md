📦 DiagPanel — A Compact Real-Time Diagnostic Panel for Neovim

🔥 Shows:

- Severity (Error / Warning / Info / Hint)
- Custom glyph or ASCII icon
- Short message
- **Exact line + column number**
- Truncated long messages for readability

A minimal, fast, non-intrusive floating diagnostics panel that shows all LSP diagnostics in the top-right corner, updating intelligently without flickering or distracting the user.


🚀 Features:

📌 Always-visible diagnostics panel in the top-right corner

🧙 Custom glyphs/emojis or ASCII symbols

✏️ Live typing mode (auto-hide INFO/HINT during Insert mode)

🔕 Optional severity threshold

🚫 No popup flickering

🔁 Auto-refresh on DiagnosticChanged, BufEnter, CursorHold

⚡ Lightweight — no dependencies, pure Lua

---------------------------------------------------------------------------------------------------------------------------

🧩 Works With Any LSP

DiagPanel uses built-in Neovim LSP diagnostics API:

* vim.diagnostic.get()

* DiagnosticChanged events

* underline, virtual_text, signs, etc.

It works out-of-the-box as long as your LSP is configured (through nvim-lspconfig, mason, etc.)

---------------------------------------------------------------------------------------------------------------------------

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
    live_typing = true,         -- Panel updates during Insert mode while typing (set it to false if it's noisy)
    severity_threshold = nil,   -- use (severity_threshold = vim.diagnostic.severity.WARN) to hide INFO/HINT always
    debounce_ms = 120,          -- Delay between panel updates (prevents flicker)
    update_in_insert = false,   --Neovim LSP setting, set it to false for cleaner typing 


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

    show_on_bufenter = true,      -- show panel automatically when you open a file
    show_on_diag_changed = true,  -- panel refreshes when diagnostics change
    show_on_cursorhold = true,    -- when you pause, panel refreshes
    keymap = "<Leader>p",         -- toggle panel(show or hide)
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


















