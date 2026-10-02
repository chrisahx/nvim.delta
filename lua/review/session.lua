local git = require("review.git")
local diff = require("review.diff")
local decorations = require("review.decorations")
local sidebar = require("review.sidebar")
local config = require("review.config")
local buffer = require("review.buffer")
local M = { active = nil }
local request = 0
local actions = {}
local function notify(message, level)
  vim.notify("review: " .. message, level or vim.log.levels.ERROR)
end
local function live(s)
  return M.active == s
end
local text = buffer.text

local function map_buffer(s, buf)
  if s.buffers[buf] then
    return
  end
  local saved = {}
  s.buffers[buf] = saved
  vim.api.nvim_buf_call(buf, function()
    for action, lhs in pairs(config.options.mappings) do
      if lhs and lhs ~= "" and actions[action] then
        local previous = vim.fn.maparg(lhs, "n", false, true)
        local callback = actions[action]
        vim.keymap.set(
          "n",
          lhs,
          callback,
          { buffer = buf, silent = true, desc = "Review: " .. action }
        )
        local installed = vim.fn.maparg(lhs, "n", false, true)
        saved[#saved + 1] = { lhs = installed.lhs, previous = previous, callback = callback }
      end
    end
  end)
end

local function decorate(s, file)
  local buf = file.buf
  if not live(s) or not buf or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  file.request = (file.request or 0) + 1
  local token, generation = file.request, s.generation
  local function apply(old, err)
    if not live(s) or s.generation ~= generation or token ~= file.request then
      return
    end
    if not vim.api.nvim_buf_is_loaded(buf) then
      return
    end
    if not old then
      notify(err)
      return
    end
    file.old = old
    if file.status == "D" then
      -- Deleted buffers show the base text itself, not a second virtual copy.
      file.hunks = diff.compute(old, "")
      decorations.clear(buf)
      for row = 0, vim.api.nvim_buf_line_count(buf) - 1 do
        vim.api.nvim_buf_set_extmark(buf, decorations.namespace, row, 0, {
          line_hl_group = "ReviewDelete",
          sign_text = file.staged and not file.unstaged and "┃" or nil,
          sign_hl_group = "ReviewStagedSign",
        })
      end
    else
      local current = text(buf)
      -- Vim 0.10 treats strings containing NUL as Blobs, which sha256 rejects.
      -- The base is pinned; only current text needs a fingerprint.
      local fingerprint = vim.fn.sha256((current:gsub("%z", "\n")))
      if file.fingerprint and file.fingerprint ~= fingerprint then
        file.reviewed = false
      end
      file.fingerprint = fingerprint
      file.hunks, file.binary = diff.compute(buffer.normalize(buf, old), current)
      file.staged_rows = nil
      decorations.apply(buf, file.hunks)
      if file.staged and not file.binary then
        local tick = vim.api.nvim_buf_get_changedtick(buf)
        require("review.staging").load(s.root, file, buf, function(rows)
          if
            not rows
            or not live(s)
            or s.generation ~= generation
            or token ~= file.request
            or not vim.api.nvim_buf_is_loaded(buf)
            or vim.api.nvim_buf_get_changedtick(buf) ~= tick
          then
            return
          end
          file.staged_rows = rows
          decorations.apply(buf, file.hunks, rows)
        end)
      end
      if file.binary and not file.warned then
        file.warned = true
        notify("Binary content has no inline overlay: " .. file.path, vim.log.levels.WARN)
      end
    end
    sidebar.render(s)
  end
  if file.old ~= nil then
    apply(file.old)
  else
    git.content(s.root, s.commit, file, apply)
  end
end

local function source_window(s)
  if s.source_win and vim.api.nvim_win_is_valid(s.source_win) then
    return s.source_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= s.sidebar_win then
      s.source_win = win
      return win
    end
  end
  vim.cmd("vsplit")
  s.source_win = vim.api.nvim_get_current_win()
  return s.source_win
end

function M.open(index)
  local s = M.active
  if not s or not s.files[index] then
    return
  end
  local file = s.files[index]
  s.open_request = (s.open_request or 0) + 1
  local opening = s.open_request
  local win = source_window(s)
  local function show(buf)
    if not live(s) or opening ~= s.open_request or not vim.api.nvim_win_is_valid(win) then
      return
    end
    local ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)
    if not ok then
      notify(tostring(err))
      return
    end
    file.buf = buf
    s.index = index
    map_buffer(s, buf)
    decorate(s, file)
    vim.api.nvim_set_current_win(win)
    sidebar.render(s)
  end
  if file.status == "D" then
    if file.buf and vim.api.nvim_buf_is_valid(file.buf) then
      show(file.buf)
      return
    end
    git.content(s.root, s.commit, file, function(old, err)
      if not live(s) or s.files[index] ~= file or opening ~= s.open_request then
        return
      end
      if not old then
        notify(err)
        return
      end
      file.old = old
      local buf = vim.api.nvim_create_buf(false, true)
      s.deleted_buffers[buf] = true
      vim.api.nvim_buf_set_name(buf, "review-deleted://" .. s.id .. "/" .. file.path)
      local lines = vim.split(old, "\n", { plain = true })
      if lines[#lines] == "" then
        table.remove(lines)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      vim.bo[buf].readonly = true
      vim.bo[buf].filetype = vim.filetype.match({ filename = file.path }) or ""
      show(buf)
    end)
    return
  end
  local path = s.root .. "/" .. file.path
  local stat = vim.uv.fs_lstat(path)
  if not stat or stat.type ~= "file" then
    notify(
      "File missing or unsupported symlink/directory/submodule: "
        .. file.path
        .. "; try :ReviewRefresh"
    )
    return
  end
  local ok, buf = pcall(function()
    local b = vim.fn.bufadd(path)
    vim.fn.bufload(b)
    return b
  end)
  if not ok then
    notify("Cannot load " .. file.path .. ": " .. tostring(buf))
    return
  end
  show(buf)
end

function M.close()
  request = request + 1
  local s = M.active
  if not s then
    return
  end
  M.active = nil
  if s.augroup then
    vim.api.nvim_del_augroup_by_id(s.augroup)
  end
  for buf, maps in pairs(s.buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      decorations.clear(buf)
      local current_maps = vim.api.nvim_buf_get_keymap(buf, "n")
      for _, mapping in ipairs(maps) do
        for _, current in ipairs(current_maps) do
          if current.lhs == mapping.lhs and current.callback == mapping.callback then
            pcall(vim.keymap.del, "n", mapping.lhs, { buffer = buf })
            local previous = mapping.previous
            if previous.buffer == 1 then
              if vim.api.nvim_buf_is_loaded(buf) then
                vim.api.nvim_buf_call(buf, function()
                  vim.fn.mapset("n", false, previous)
                end)
              else
                -- Do not reload a missing/deleted file just to restore a mapping.
                local rhs = (previous.rhs or ""):gsub("<SID>", "<SNR>" .. previous.sid .. "_")
                vim.api.nvim_buf_set_keymap(buf, "n", previous.lhs, rhs, {
                  callback = previous.callback,
                  noremap = previous.noremap == 1,
                  silent = previous.silent == 1,
                  expr = previous.expr == 1,
                  nowait = previous.nowait == 1,
                  script = previous.script == 1,
                  desc = previous.desc,
                })
              end
            end
          end
        end
      end
    end
  end
  sidebar.close(s)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if s.deleted_buffers[vim.api.nvim_win_get_buf(win)] then
      local replacement
      for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(candidate)
        if
          vim.api.nvim_buf_is_loaded(candidate)
          and vim.bo[candidate].buftype == ""
          and (name == "" or vim.uv.fs_stat(name))
          and not s.deleted_buffers[candidate]
        then
          replacement = candidate
          break
        end
      end
      -- Avoid Neovim implicitly reloading a now-missing alternate source buffer.
      pcall(vim.api.nvim_win_set_buf, win, replacement or vim.api.nvim_create_buf(true, false))
    end
  end
  for buf in pairs(s.deleted_buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function M.refresh()
  local s = M.active
  if not s then
    notify("No active review", vim.log.levels.WARN)
    return
  end
  s.generation = s.generation + 1
  local generation = s.generation
  git.files(s.root, s.commit, function(files, err)
    if not live(s) or generation ~= s.generation then
      return
    end
    if not files then
      notify(err)
      return
    end
    local previous, current_path = {}, s.files[s.index or 1] and s.files[s.index or 1].path
    for _, file in ipairs(s.files) do
      file.request = (file.request or 0) + 1
      previous[file.path] = file
    end
    local present = {}
    for _, file in ipairs(files) do
      present[file.path] = true
    end
    -- Preserve dirty review buffers even if the filesystem has reverted to the base.
    for _, old in ipairs(s.files) do
      if
        not present[old.path]
        and old.status ~= "D"
        and old.old
        and old.buf
        and vim.api.nvim_buf_is_loaded(old.buf)
        and vim.bo[old.buf].modified
        and text(old.buf) ~= buffer.normalize(old.buf, old.old)
      then
        files[#files + 1] = {
          path = old.path,
          status = old.status,
          reviewed = false,
          hunks = {},
          signature = old.signature,
        }
      end
    end
    table.sort(files, function(a, b)
      return a.path < b.path
    end)
    for buf in pairs(s.buffers) do
      decorations.clear(buf)
    end
    s.files = files
    s.index = nil
    for index, file in ipairs(files) do
      local old = previous[file.path]
      if old then
        file.reviewed = old.reviewed
          and old.signature == file.signature
          and old.status == file.status
        file.fingerprint, file.buf = old.fingerprint, old.buf
        if file.status == old.status then
          file.old = old.old
        end
        -- A transition between real/deleted buffers must not reuse the wrong buffer type.
        if (file.status == "D") ~= (old.status == "D") then
          file.buf = nil
        end
      end
      if file.path == current_path then
        s.index = index
      end
      if file.status ~= "D" then
        local path = s.root .. "/" .. file.path
        local stat = vim.uv.fs_lstat(path)
        if not stat or stat.type ~= "file" then
          file.buf = nil
        elseif not file.buf then
          local buf = vim.fn.bufnr(path)
          if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
            file.buf = buf
          end
        end
      end
      if file.buf then
        map_buffer(s, file.buf)
        decorate(s, file)
      end
    end
    s.index = s.index or (#files > 0 and 1 or nil)
    sidebar.render(s)
    -- Do not steal focus on save, even when the current file becomes unchanged.
  end)
end

function M.start(base)
  local name = vim.api.nvim_buf_get_name(0)
  local cwd = name ~= "" and vim.bo.buftype == "" and vim.fs.dirname(name) or vim.fn.getcwd()
  request = request + 1
  local token = request
  git.root(cwd, function(root, err)
    if token ~= request then
      return
    end
    if not root then
      notify(err)
      return
    end
    git.resolve(
      root,
      base or config.options.base,
      config.options.use_merge_base,
      function(resolved, resolve_err)
        if token ~= request then
          return
        end
        if not resolved then
          notify(resolve_err)
          return
        end
        git.files(root, resolved.commit, function(files, files_err)
          if token ~= request then
            return
          end
          if not files then
            notify(files_err)
            return
          end
          M.close()
          local s = {
            id = request,
            root = root,
            base = resolved.name,
            commit = resolved.commit,
            files = files,
            index = #files > 0 and 1 or nil,
            generation = 0,
            buffers = {},
            deleted_buffers = {},
            namespace = decorations.namespace,
          }
          M.active = s
          sidebar.open(s, config.options, actions)
          s.augroup = vim.api.nvim_create_augroup("ReviewSession", { clear = true })
          vim.api.nvim_create_autocmd("BufWritePost", {
            group = s.augroup,
            callback = function(event)
              if not config.options.refresh.on_write then
                return
              end
              local path = vim.api.nvim_buf_get_name(event.buf)
              if path:sub(1, #s.root + 1) == s.root .. "/" then
                M.refresh()
              end
            end,
          })
          vim.api.nvim_create_autocmd("BufEnter", {
            group = s.augroup,
            callback = function(event)
              if not live(s) then
                return
              end
              local path = vim.api.nvim_buf_get_name(event.buf)
              for index, file in ipairs(s.files) do
                local stat = path == s.root .. "/" .. file.path and vim.uv.fs_lstat(path)
                if file.status ~= "D" and stat and stat.type == "file" then
                  file.buf, s.index = event.buf, index
                  map_buffer(s, event.buf)
                  decorate(s, file)
                  sidebar.render(s)
                  break
                end
              end
            end,
          })
          vim.api.nvim_create_autocmd("BufWipeout", {
            group = s.augroup,
            buffer = s.sidebar_buf,
            callback = function()
              vim.schedule(function()
                if live(s) then
                  M.close()
                end
              end)
            end,
          })
          if #files > 0 then
            M.open(1)
          end
        end)
      end
    )
  end)
end

local function selected(s)
  if vim.api.nvim_get_current_buf() == s.sidebar_buf then
    return sidebar.selected(s)
  end
  local buf = vim.api.nvim_get_current_buf()
  for index, file in ipairs(s.files) do
    if file.buf == buf then
      return index
    end
  end
end
function M.reviewed(value)
  local s = M.active
  if not s then
    return
  end
  local index = selected(s)
  local file = index and s.files[index]
  if not file then
    return
  end
  if value == nil then
    file.reviewed = not file.reviewed
  else
    file.reviewed = value
  end
  sidebar.render(s)
end
function M.move_file(direction)
  local s = M.active
  if not s or #s.files == 0 then
    return
  end
  local index = selected(s) or s.index or (direction > 0 and 0 or 1)
  M.open((index - 1 + direction) % #s.files + 1)
end
function M.move_hunk(direction)
  local s = M.active
  if not s then
    return
  end
  local index = selected(s)
  local file = index and s.files[index]
  if not file or vim.api.nvim_get_current_buf() ~= file.buf or #file.hunks == 0 then
    return
  end
  local count = vim.api.nvim_buf_line_count(file.buf)
  local rows = {}
  for _, hunk in ipairs(file.hunks) do
    rows[#rows + 1] = diff.row(hunk, count) + 1
  end
  local current = vim.api.nvim_win_get_cursor(0)[1]
  local target = direction > 0 and rows[1] or rows[#rows]
  if direction > 0 then
    for _, row in ipairs(rows) do
      if row > current then
        target = row
        break
      end
    end
  else
    for i = #rows, 1, -1 do
      if rows[i] < current then
        target = rows[i]
        break
      end
    end
  end
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd("normal! zv")
end

function M.update_buffer(file)
  local s = M.active
  if s then
    decorate(s, file)
  end
end

function M.progress()
  local s, done = M.active, 0
  if not s then
    return { reviewed = 0, total = 0 }
  end
  for _, file in ipairs(s.files) do
    if file.reviewed then
      done = done + 1
    end
  end
  return { reviewed = done, total = #s.files }
end

actions.open = function()
  local s = M.active
  if s then
    M.open(sidebar.selected(s))
  end
end
actions.next_file = function()
  M.move_file(1)
end
actions.prev_file = function()
  M.move_file(-1)
end
actions.next_hunk = function()
  M.move_hunk(1)
end
actions.prev_hunk = function()
  M.move_hunk(-1)
end
actions.toggle_reviewed = function()
  M.reviewed()
end
for _, action in ipairs({ "stage_hunk", "unstage_hunk", "discard_hunk", "restore_base_hunk" }) do
  actions[action] = function()
    require("review.operations").run(action)
  end
end
actions.refresh = M.refresh
actions.close = M.close
M.actions = actions
return M
