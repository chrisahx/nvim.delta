local M = {}
local histories = {}

local function options(buf)
  return { endofline = vim.bo[buf].endofline, fixendofline = vim.bo[buf].fixendofline }
end
local function tree(buf)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.undotree()
  end)
end
local function active_records(history, undo)
  local parents = {}
  local function visit(entries, parent)
    for _, entry in ipairs(entries or {}) do
      if entry.alt then
        visit(entry.alt, parent)
      end
      parents[entry.seq] = parent
      parent = entry.seq
    end
  end
  visit(undo.entries, 0)
  local active, seq = {}, undo.seq_cur
  while seq and seq ~= 0 do
    if history.records[seq] then
      table.insert(active, 1, seq)
    end
    seq = parents[seq]
  end
  return active
end

-- Vim's undo tree restores text, but does not restore 'endofline'/'fixendofline'.
-- Track option transitions on our undo nodes, including alternate undo branches.
function M.sync(buf)
  local history = histories[buf]
  if not history or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  local active = active_records(history, tree(buf))
  local common = 0
  while active[common + 1] and active[common + 1] == history.active[common + 1] do
    common = common + 1
  end
  local state
  if #active > common then
    state = history.records[active[#active]].after
  elseif #history.active > common then
    state = history.records[history.active[common + 1]].before
  end
  if state then
    vim.bo[buf].endofline, vim.bo[buf].fixendofline = state.endofline, state.fixendofline
  end
  history.active = active
end

local function record(buf, before, after)
  if vim.deep_equal(before, after) then
    return
  end
  local history = histories[buf]
  if not history then
    history = {
      records = {},
      active = {},
      group = vim.api.nvim_create_augroup("DeltaEOF" .. buf, { clear = true }),
    }
    histories[buf] = history
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePre" }, {
      buffer = buf,
      group = history.group,
      callback = function()
        M.sync(buf)
      end,
      desc = "Restore Delta hunk EOF options on undo/redo",
    })
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
      buffer = buf,
      group = history.group,
      once = true,
      callback = function()
        histories[buf] = nil
        vim.api.nvim_del_augroup_by_id(history.group)
      end,
    })
  end
  local undo = tree(buf)
  history.records[undo.seq_cur] = { before = before, after = after }
  history.active = active_records(history, undo)
end

function M.text(buf)
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  M.sync(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local result = table.concat(lines, "\n")
  local empty = #lines == 1
    and lines[1] == ""
    and vim.api.nvim_buf_call(buf, function()
      -- These buffers have identical API lines; wordcount sees the internal empty flag.
      return vim.fn.wordcount().bytes == 0
    end)
  if vim.bo[buf].endofline and not empty then
    result = result .. "\n"
  end
  return result
end

function M.normalize(buf, text)
  if vim.bo[buf].bomb then
    text = text:gsub("^\239\187\191", "")
  end
  if vim.bo[buf].fileformat == "dos" then
    text = text:gsub("\r\n", "\n")
  end
  return text
end

function M.revert(buf, hunk)
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local current = M.text(buf)
  local before = options(buf)
  local result = require("delta.diff").revert(current, hunk)
  local replacement = {}
  for _, line in ipairs(hunk.lines) do
    if line.kind == "delete" then
      replacement[#replacement + 1] = line.text
    end
  end
  local start = hunk.new_count == 0 and hunk.new_start or hunk.new_start - 1
  vim.api.nvim_buf_call(buf, function()
    -- Keep this action separate from the user's preceding insert-mode undo block.
    vim.cmd("let &undolevels = &undolevels")
    vim.api.nvim_buf_set_lines(buf, start, start + hunk.new_count, false, replacement)
    vim.bo[buf].endofline = result:sub(-1) == "\n"
    if result ~= "" and not vim.bo[buf].endofline then
      vim.bo[buf].fixendofline = false
    end
  end)
  record(buf, before, options(buf))
end
return M
