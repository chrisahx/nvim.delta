local M = { namespace = vim.api.nvim_create_namespace("delta") }
function M.highlights()
  for name, link in pairs({
    DeltaAdd = "DiffAdd",
    DeltaDelete = "DiffDelete",
    DeltaChange = "DiffChange",
    DeltaAddSign = "DiffAdd",
    DeltaDeleteSign = "DiffDelete",
    DeltaChangeSign = "DiffChange",
    DeltaVirtualDelete = "DiffDelete",
    DeltaStagedSign = "DiagnosticOk",
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
  end
end
function M.apply(buf, hunks, staged)
  staged = staged or { lines = {}, deletions = {} }
  M.clear(buf)
  local count = vim.api.nvim_buf_line_count(buf)
  for _, hunk in ipairs(hunks) do
    local deleted, has_add = {}, false
    for _, line in ipairs(hunk.lines) do
      if line.kind == "delete" then
        deleted[#deleted + 1] = { { "- " .. line.text, "DeltaVirtualDelete" } }
      end
      if line.kind == "add" then
        has_add = true
      end
    end
    local changed = #deleted > 0 and has_add
    local row = hunk.new_start - 1
    for _, line in ipairs(hunk.lines) do
      if line.kind == "add" and row >= 0 and row < count then
        vim.api.nvim_buf_set_extmark(buf, M.namespace, row, 0, {
          line_hl_group = changed and "DeltaChange" or "DeltaAdd",
          sign_text = staged.lines[row] and "┃" or (changed and "~" or "+"),
          sign_hl_group = staged.lines[row] and "DeltaStagedSign"
            or (changed and "DeltaChangeSign" or "DeltaAddSign"),
          priority = 120,
        })
      end
      if line.kind ~= "delete" then
        row = row + 1
      end
    end
    if #deleted > 0 then
      local anchor = hunk.new_count == 0 and hunk.new_start or hunk.new_start - 1
      local after = anchor >= count
      local row = math.max(0, math.min(anchor, count - 1))
      vim.api.nvim_buf_set_extmark(buf, M.namespace, row, 0, {
        virt_lines = deleted,
        virt_lines_above = not after,
        sign_text = not has_add and (staged.deletions[row] and "┃" or "-") or nil,
        sign_hl_group = staged.deletions[row] and "DeltaStagedSign" or "DeltaDeleteSign",
        priority = 119,
      })
    end
  end
end
return M
