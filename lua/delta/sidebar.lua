local M = {}
local function display(path)
  return path:gsub("[%c]", function(c)
    return string.format("\\x%02x", c:byte())
  end)
end
function M.render(session)
  local buf = session.sidebar_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = { "Delta against " .. display(session.base), "" }
  local done = 0
  for _, file in ipairs(session.files) do
    if file.reviewed then
      done = done + 1
    end
    lines[#lines + 1] = string.format(
      "%s %s [%s%s] %s",
      file.reviewed and "✓" or "○",
      file.status,
      file.staged and "S" or "-",
      file.unstaged and "U" or "-",
      display(file.path)
    )
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("%d / %d reviewed", done, #session.files)
  if #session.files == 0 then
    lines[#lines + 1] = "No changed files"
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if session.sidebar_win and vim.api.nvim_win_is_valid(session.sidebar_win) then
    local index = session.index or 1
    if vim.api.nvim_get_current_win() == session.sidebar_win then
      local selected = vim.api.nvim_win_get_cursor(session.sidebar_win)[1] - 2
      if session.files[selected] then
        index = selected
      end
    end
    vim.api.nvim_win_set_cursor(session.sidebar_win, { math.min(index + 2, #lines), 0 })
  end
end
function M.selected(session)
  if session.sidebar_win and vim.api.nvim_win_is_valid(session.sidebar_win) then
    local index = vim.api.nvim_win_get_cursor(session.sidebar_win)[1] - 2
    if session.files[index] then
      return index
    end
  end
end
function M.open(session, options, actions)
  session.source_win = vim.api.nvim_get_current_win()
  vim.cmd(options.sidebar.position == "left" and "topleft vsplit" or "botright vsplit")
  session.sidebar_win = vim.api.nvim_get_current_win()
  session.sidebar_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(session.sidebar_win, session.sidebar_buf)
  vim.api.nvim_win_set_width(session.sidebar_win, options.sidebar.width)
  vim.bo[session.sidebar_buf].filetype = "delta"
  vim.bo[session.sidebar_buf].bufhidden = "wipe"
  for key, value in pairs({
    number = false,
    relativenumber = false,
    wrap = false,
    winfixwidth = true,
    signcolumn = "no",
  }) do
    vim.wo[session.sidebar_win][key] = value
  end
  for action, lhs in pairs(options.sidebar_mappings) do
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, actions[action], { buffer = session.sidebar_buf, silent = true })
    end
  end
  for _, action in ipairs({ "next_file", "prev_file" }) do
    local lhs = options.mappings[action]
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, actions[action], { buffer = session.sidebar_buf, silent = true })
    end
  end
  M.render(session)
  vim.api.nvim_set_current_win(session.source_win)
end
function M.close(session)
  if session.sidebar_win and vim.api.nvim_win_is_valid(session.sidebar_win) then
    pcall(vim.api.nvim_win_close, session.sidebar_win, true)
  end
  if session.sidebar_buf and vim.api.nvim_buf_is_valid(session.sidebar_buf) then
    pcall(vim.api.nvim_buf_delete, session.sidebar_buf, { force = true })
  end
end
return M
