local M = {}
M.defaults = {
  base = nil,
  use_merge_base = true,
  sidebar = { width = 35, position = "left" },
  mappings = {
    next_hunk = "]h",
    prev_hunk = "[h",
    next_file = "]f",
    prev_file = "[f",
    toggle_reviewed = "<leader>rr",
  },
  sidebar_mappings = { open = "<CR>", toggle_reviewed = "r", refresh = "R", close = "q" },
  refresh = { on_write = true },
}
M.options = vim.deepcopy(M.defaults)
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  assert(
    M.options.sidebar.position == "left" or M.options.sidebar.position == "right",
    "review: sidebar.position must be left or right"
  )
  assert(
    type(M.options.sidebar.width) == "number" and M.options.sidebar.width > 0,
    "review: sidebar.width must be positive"
  )
end
return M
