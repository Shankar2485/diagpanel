-- lua/diagpanel/init.lua
-- DiagPanel: compact top-right diagnostics panel
-- Usage: require('diagpanel').setup(opts)

local api = vim.api
local uv = vim.loop
local diag = vim.diagnostic

local M = {}

-- Default options (override via setup)
local default_opts = {
    use_ascii = false,
    width_fraction = 0.45, -- max width fraction of editor
    height_fraction = 0.25, -- max height fraction of editor
    max_lines_min = 3,   -- minimum panel rows when diags exist
    max_msg_len = 80,    -- truncate message length
    winblend = 45,
    border = "rounded",
    zindex = 300,
    glyphs = { ERROR = "⛔", WARN = "🧙", INFO = "🔮", HINT = "💡" },
    ascii = { ERROR = "E", WARN = "W", INFO = "I", HINT = "H" },
    highlight = {
        error = { fg = "#ff6b6b", bg = "NONE", bold = true },
        warn = { fg = "#e0af68", bg = "NONE", italic = true },
        info = { fg = "#7aa2f7", bg = "NONE" },
        hint = { fg = "#9ece6a", bg = "NONE", italic = true },
        border = { fg = "#88c0d0", bg = "NONE", bold = true },
    },
    show_on_bufenter = true,
    show_on_diag_changed = true,
    show_on_cursorhold = true, -- will re-open if panel already exists
    debounce_ms = 80,
    keymap = "<Leader>p",
    buffer_keymaps = true, -- maps <CR>, q, <Esc> inside the panel buffer
    float_opts = {
        border = "rounded",
        source = "always",
    },
    live_typing = false,
}

-- Panel state
local panel = {
    win = nil,
    buf = nil,
    buf_for = nil,
    items = nil,
    timer = nil,
    last_version = nil,
    closing = false,
}

-- Will be filled by setup
local opts = vim.deepcopy(default_opts)

-- helpers
local function is_win(w)
    return w and api.nvim_win_is_valid(w)
end
local function is_buf(b)
    return b and api.nvim_buf_is_valid(b)
end

local function safe_close_handle(h)
    if not h then
        return
    end
    local ok, closing = pcall(function()
        return type(h.is_closing) == "function" and h:is_closing()
    end)
    if ok and closing then
        return
    end
    pcall(function()
        if type(h.stop) == "function" then
            h:stop()
        end
    end)
    pcall(function()
        if type(h.close) == "function" then
            h:close()
        end
    end)
end

local function sev_glyph(s)
    if s == diag.severity.ERROR then
        return opts.use_ascii and opts.ascii.ERROR or opts.glyphs.ERROR
    end
    if s == diag.severity.WARN then
        return opts.use_ascii and opts.ascii.WARN or opts.glyphs.WARN
    end
    if s == diag.severity.INFO then
        return opts.use_ascii and opts.ascii.INFO or opts.glyphs.INFO
    end
    if s == diag.severity.HINT then
        return opts.use_ascii and opts.ascii.HINT or opts.glyphs.HINT
    end
    return opts.use_ascii and opts.ascii.INFO or opts.glyphs.INFO
end

local function sev_name(s)
    if s == diag.severity.ERROR then
        return "ERROR"
    end
    if s == diag.severity.WARN then
        return "WARN"
    end
    if s == diag.severity.INFO then
        return "INFO"
    end
    if s == diag.severity.HINT then
        return "HINT"
    end
    return "DIAG"
end

local function ensure_buf()
    if panel.buf and is_buf(panel.buf) then
        return panel.buf
    end
    panel.buf = api.nvim_create_buf(false, true)
    if is_buf(panel.buf) then
        api.nvim_buf_set_name(panel.buf, "DiagPanel")
        api.nvim_buf_set_option(panel.buf, "buftype", "nofile")
        api.nvim_buf_set_option(panel.buf, "bufhidden", "wipe")
        api.nvim_buf_set_option(panel.buf, "swapfile", false)
        api.nvim_buf_set_option(panel.buf, "modifiable", false)
        api.nvim_buf_set_option(panel.buf, "filetype", "diagpanel")
    end
    return panel.buf
end

local function close_panel()
    if panel.closing then
        return
    end
    panel.closing = true
    if is_win(panel.win) then
        pcall(api.nvim_win_close, panel.win, true)
    end
    if is_buf(panel.buf) then
        pcall(api.nvim_buf_delete, panel.buf, { force = true })
    end
    panel.win = nil
    panel.buf = nil
    panel.items = nil
    panel.buf_for = nil
    panel.last_version = nil
    panel.closing = false
end

local function stop_timer()
    if not panel.timer then
        return
    end
    safe_close_handle(panel.timer)
    panel.timer = nil
end

local function format_one(d)
    local ln = d.range and d.range.start and d.range.start.line or (d.lnum or 0)
    local ch = d.range and d.range.start and d.range.start.character or (d.col or 0)
    local glyph = sev_glyph(d.severity)
    local name = sev_name(d.severity)
    local msg = (d.message or ""):gsub("%s+", " "):gsub("\n", " ")
    if #msg > opts.max_msg_len then
        msg = vim.fn.strcharpart(msg, 0, opts.max_msg_len - 3) .. "…"
    end
    return string.format("%s %s line %d:%d -- %s", glyph, name, ln + 1, ch + 1, msg), ln, ch
end

-- Build panel lines for bufnr, dedupe identical line+col+message
local function build_lines(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    local diags = diag.get(bufnr)
    if not diags or vim.tbl_isempty(diags) then
        return nil
    end

    local seen = {}
    local lines = {}
    local items = {}

    -- convenience local of configured threshold (may be nil)
    local thr = opts.severity_threshold

    -- dynamic threshold: in insert mode + live_typing → hide INFO/HINT
    local mode_ok, mode = pcall(api.nvim_get_mode)
    local in_insert = mode_ok and mode and mode.mode == "i"

    if in_insert and opts.live_typing then
        -- HINT=4, INFO=3, WARN=2, ERROR=1
        -- Setting threshold to WARN hides INFO & HINT during typing
        thr = vim.diagnostic.severity.WARN
    end

    for _, d in ipairs(diags) do
        -- if user set a threshold, only include diagnostics with severity <= threshold
        -- (neovim: ERROR=1, WARN=2, INFO=3, HINT=4; smaller = more severe)
        if not thr or (d.severity and d.severity <= thr) then
            local key_ln = d.range and d.range.start and d.range.start.line or (d.lnum or 0)
            local key_ch = d.range and d.range.start and d.range.start.character or (d.col or 0)
            local key_msg = (d.message or ""):sub(1, 120)
            local key = key_ln .. ":" .. key_ch .. ":" .. key_msg
            if not seen[key] then
                seen[key] = true
                local s, ln, ch = format_one(d)
                table.insert(lines, s)
                table.insert(items, { diag = d, bufnr = bufnr, lnum = ln, col = ch })
            end
        end
    end

    return lines, items
end

local function do_panel(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    local lines, items = build_lines(bufnr)
    if not lines then
        if panel.buf_for == bufnr then
            close_panel()
        end
        return
    end

    -- simple change detection to avoid flicker
    local ver = tostring(#lines) .. ":" .. (lines[1] or "")
    if panel.last_version == ver and panel.buf_for == bufnr then
        return
    end
    panel.last_version = ver
    panel.buf_for = bufnr
    panel.items = items

    -- compute width/height
    local maxlen = 0
    for _, ln in ipairs(lines) do
        maxlen = math.max(maxlen, vim.fn.strdisplaywidth(ln))
    end
    local maxw = math.floor(vim.o.columns * opts.width_fraction)
    local width = math.min(maxlen, maxw)
    for i, ln in ipairs(lines) do
        if vim.fn.strdisplaywidth(ln) > width then
            lines[i] = vim.fn.strcharpart(ln, 0, width - 1) .. "…"
        end
    end
    local height = math.min(#lines, math.max(opts.max_lines_min, math.floor(vim.o.lines * opts.height_fraction)))

    local buf = ensure_buf()
    if not is_buf(buf) then
        return
    end

    pcall(api.nvim_buf_set_option, buf, "modifiable", true)
    pcall(api.nvim_buf_set_lines, buf, 0, -1, false, lines)
    pcall(api.nvim_buf_set_option, buf, "modifiable", false)

    -- highlight lines by severity
    pcall(function()
        api.nvim_buf_clear_namespace(buf, -1, 0, -1)
        for i, it in ipairs(panel.items) do
            local s = it.diag.severity
            local hl = "DiagnosticVirtualTextInfo"
            if s == diag.severity.ERROR then
                hl = "DiagnosticVirtualTextError"
            elseif s == diag.severity.WARN then
                hl = "DiagnosticVirtualTextWarn"
            elseif s == diag.severity.HINT then
                hl = "DiagnosticVirtualTextHint"
            end
            pcall(api.nvim_buf_add_highlight, buf, -1, hl, i - 1, 0, -1)
        end
    end)

    local row = 1
    local col = math.max(1, vim.o.columns - width - 4)

    -- reuse window if valid, otherwise create new floating window in top-right
    if is_win(panel.win) and is_buf(panel.buf) then
        if api.nvim_win_get_buf(panel.win) ~= buf then
            pcall(api.nvim_win_set_buf, panel.win, buf)
        end
        local cfg = {
            relative = "editor",
            anchor = "NW",
            row = row,
            col = col,
            width = width + 2,
            height = height,
            style = "minimal",
        }
        pcall(api.nvim_win_set_config, panel.win, cfg)
    else
        -- ensure any previous window is cleaned
        if is_win(panel.win) then
            pcall(api.nvim_win_close, panel.win, true)
        end
        -- open new
        local win_opts = {
            relative = "editor",
            anchor = "NW",
            row = row,
            col = col,
            width = width + 2,
            height = height,
            style = "minimal",
            border = opts.border,
            zindex = opts.zindex,
        }
        local ok, win = pcall(api.nvim_open_win, buf, false, win_opts)
        if ok and type(win) == "number" then
            panel.win = win
            -- make interior transparent and set a stronger border color (tweak hex as you like)
            pcall(api.nvim_set_hl, 0, "DiagPanelBg", { bg = "NONE" })
            pcall(api.nvim_set_hl, 0, "DiagPanelBorder", { fg = "#88c0d0", bg = "NONE", bold = true })

            pcall(api.nvim_win_set_option, panel.win, "winblend", opts.winblend)
            pcall(api.nvim_win_set_option, panel.win, "wrap", false)
            pcall(api.nvim_win_set_option, panel.win, "cursorline", false)
            pcall(api.nvim_win_set_option, panel.win, "number", false)
            pcall(api.nvim_win_set_option, panel.win, "relativenumber", false)
            pcall(api.nvim_win_set_option, panel.win, "signcolumn", "no")
            pcall(api.nvim_win_set_option, panel.win, "foldcolumn", "0")
            pcall(api.nvim_win_set_option, panel.win, "winhl", "Normal:DiagPanelBg,FloatBorder:DiagPanelBorder")

            -- Re-apply highlights + winhl a few times to beat later theme/autocmd changes.
            -- Using multiple small defers is low-cost and robust across different theme hooks.
            local function reapply_winhl_once()
                if panel.win and api.nvim_win_is_valid(panel.win) then
                    pcall(api.nvim_set_hl, 0, "DiagPanelBg", { bg = "NONE" })
                    pcall(api.nvim_set_hl, 0, "DiagPanelBorder", { fg = "#88c0d0", bg = "NONE", bold = true })
                    pcall(api.nvim_win_set_option, panel.win, "winhl", "Normal:DiagPanelBg,FloatBorder:DiagPanelBorder")
                    pcall(api.nvim_win_set_option, panel.win, "winblend", opts.winblend)
                end
            end

            -- schedule multiple reapplications (30ms, 120ms, 350ms)
            vim.defer_fn(reapply_winhl_once, 30)
            vim.defer_fn(reapply_winhl_once, 120)
            vim.defer_fn(reapply_winhl_once, 350)
        else
            panel.win = nil
        end
    end

    -- buffer keymaps for panel
    if is_buf(buf) then
        pcall(
            api.nvim_buf_set_keymap,
            buf,
            "n",
            "<CR>",
            "<Cmd>lua require('diagpanel').jump()<CR>",
            { nowait = true, noremap = true, silent = true }
        )
        pcall(
            api.nvim_buf_set_keymap,
            buf,
            "n",
            "q",
            "<Cmd>lua require('diagpanel').close()<CR>",
            { nowait = true, noremap = true, silent = true }
        )
        pcall(
            api.nvim_buf_set_keymap,
            buf,
            "n",
            "<Esc>",
            "<Cmd>lua require('diagpanel').close()<CR>",
            { nowait = true, noremap = true, silent = true }
        )
    end
end

-- debounced open using uv timer
local function open_panel(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    stop_timer()
    panel.timer = uv.new_timer()
    if not panel.timer then
        -- fallback immediate
        do_panel(bufnr)
        return
    end
    local t = panel.timer
    -- start safely, wrapped (guard start field then pcall the start call)
    local ok = pcall(function()
        if t and type(t.start) == "function" then
            pcall(function()
                t:start(
                    opts.debounce_ms,
                    0,
                    vim.schedule_wrap(function()
                        pcall(function()
                            do_panel(bufnr)
                        end)
                        stop_timer()
                    end)
                )
            end)
        else
            -- fallback if timer methods unavailable
            do_panel(bufnr)
            stop_timer()
        end
    end)
    if not ok then
        -- fallback immediate
        do_panel(bufnr)
        stop_timer()
    end
end

-- jump from the panel to source diagnostic
function M.jump()
    if not is_win(panel.win) then
        return
    end
    local ok, cur = pcall(api.nvim_win_get_cursor, panel.win)
    if not ok or not cur then
        return
    end
    local row = cur[1]
    local item = panel.items and panel.items[row]
    if not item then
        return
    end
    local d = item.diag
    local bufnr = item.bufnr
    close_panel()
    if is_buf(bufnr) then
        api.nvim_set_current_buf(bufnr)
        local lnum = (d.lnum or (d.range and d.range.start.line) or 0) + 1
        local col = (d.col or (d.range and d.range.start.character) or 0)
        pcall(api.nvim_win_set_cursor, 0, { lnum, col })
        diag.open_float(nil, { focus = false, scope = "line" })
    end
end

function M.close()
    close_panel()
end

function M.open()
    if is_win(panel.win) then
        close_panel()
    else
        open_panel(api.nvim_get_current_buf())
    end
end

-- reapply diagnostic signs (call after plugins loaded / on VimEnter)
local function apply_diag_signs()
    local signs_text = {
        [diag.severity.ERROR] = opts.use_ascii and opts.ascii.ERROR or opts.glyphs.ERROR,
        [diag.severity.WARN] = opts.use_ascii and opts.ascii.WARN or opts.glyphs.WARN,
        [diag.severity.INFO] = opts.use_ascii and opts.ascii.INFO or opts.glyphs.INFO,
        [diag.severity.HINT] = opts.use_ascii and opts.ascii.HINT or opts.glyphs.HINT,
    }

    local signs_texthl = {
        [diag.severity.ERROR] = "DiagnosticSignError",
        [diag.severity.WARN] = "DiagnosticSignWarn",
        [diag.severity.INFO] = "DiagnosticSignInfo",
        [diag.severity.HINT] = "DiagnosticSignHint",
    }

    -- define the named signs explicitly using sign_define (more robust than only diag.config)
    local function define_signs()
        -- map severity constants to names we defined above
        for sev, text in pairs(signs_text) do
            local name = (sev == diag.severity.ERROR and "DiagnosticSignError")
                or (sev == diag.severity.WARN and "DiagnosticSignWarn")
                or (sev == diag.severity.INFO and "DiagnosticSignInfo")
                or (sev == diag.severity.HINT and "DiagnosticSignHint")
                or "DiagnosticSignInfo"
            -- defensive: call sign_define in pcall to avoid errors on older neovim builds
            pcall(vim.fn.sign_define, name, { text = text, texthl = signs_texthl[sev], numhl = "" })
        end
    end

    -- also set diag.config signs mapping so virtual sign behavior follows the same glyphs
    pcall(function()
        local ok, existing = pcall(diag.config)
        existing = (ok and existing) or {}
        diag.config(vim.tbl_extend("force", existing, {
            signs = { text = signs_text, texthl = signs_texthl },
        }))
    end)

    -- immediately (and deferred) apply sign definitions to beat colorscheme/plugin overrides
    define_signs()
    vim.defer_fn(define_signs, 50)
    vim.defer_fn(define_signs, 200)
    vim.defer_fn(define_signs, 700)
end

-- Apply highlight tweaks used in panel
local function apply_highlights()
    pcall(api.nvim_set_hl, 0, "DiagnosticVirtualTextError", opts.highlight.error)
    pcall(api.nvim_set_hl, 0, "DiagnosticVirtualTextWarn", opts.highlight.warn)
    pcall(api.nvim_set_hl, 0, "DiagnosticVirtualTextInfo", opts.highlight.info)
    pcall(api.nvim_set_hl, 0, "DiagnosticVirtualTextHint", opts.highlight.hint)
    pcall(api.nvim_set_hl, 0, "DiagPanelBorder", opts.highlight.border)
    pcall(api.nvim_set_hl, 0, "DiagPanelBg", { bg = "NONE" })
end

-- Setup function
function M.setup(user_opts)
    opts = vim.tbl_deep_extend("force", vim.deepcopy(default_opts), user_opts or {})

    -- configure diagnostic default visuals + virtual_text prefix from glyphs
    local ok, existing = pcall(diag.config)
    existing = (ok and existing) or {}
    pcall(function()
        diag.config(vim.tbl_extend("force", existing, {
            virtual_text = {
                spacing = 1,
                prefix = function(d)
                    if d and d.severity then
                        return sev_glyph(d.severity)
                    end
                    return sev_glyph(nil)
                end,
            },
            signs = true,
            underline = true,
            update_in_insert = false,
            severity_sort = true,
            float = opts.float_opts,
        }))
    end)

    apply_highlights()

    local ag = api.nvim_create_augroup("DiagPanelGroup", { clear = true })

    if opts.show_on_diag_changed then
        api.nvim_create_autocmd("DiagnosticChanged", {
            group = ag,
            callback = function(args)
                -- If live_typing is false, ignore DiagnosticChanged events fired while in insert mode.
                -- This prevents noisy updates while the user is typing.
                local mode_ok, mode = pcall(api.nvim_get_mode)
                local in_insert = mode_ok and mode and mode.mode == "i"
                if in_insert and not opts.live_typing then
                    return
                end
                open_panel(args.buf)
            end,
        })
    end
    if opts.show_on_bufenter then
        api.nvim_create_autocmd("BufEnter", {
            group = ag,
            callback = function(args)
                open_panel(args.buf)
            end,
        })
    end
    if opts.show_on_cursorhold then
        api.nvim_create_autocmd("CursorHold", {
            group = ag,
            callback = function()
                if is_win(panel.win) then
                    open_panel(api.nvim_get_current_buf())
                end
            end,
        })
    end

    -- reapply signs after startup
    vim.schedule(apply_diag_signs)
    api.nvim_create_autocmd("VimEnter", { once = true, callback = apply_diag_signs })

    -- global keymap
    if opts.keymap and #opts.keymap > 0 then
        api.nvim_set_keymap(
            "n",
            opts.keymap,
            "<Cmd>lua require('diagpanel').open()<CR>",
            { noremap = true, silent = true }
        )
    end

    api.nvim_create_autocmd("VimLeavePre", {
        group = ag,
        callback = function()
            stop_timer()
            close_panel()
        end,
    })

    -- expose current options for other plugins to query
    function M._opts()
        return opts
    end
end

return M
