local M = {}
function M.register()
  vim.api.nvim_create_user_command("Review", function(args)
    require("review").start(args.args ~= "" and args.args or nil)
  end, { nargs = "?", desc = "Review working tree against a Git base" })
  for command, action in pairs({
    ReviewClose = "close",
    ReviewRefresh = "refresh",
    ReviewToggleReviewed = "toggle_reviewed",
    ReviewMarkReviewed = "mark_reviewed",
    ReviewMarkUnreviewed = "mark_unreviewed",
    ReviewNextFile = "next_file",
    ReviewPrevFile = "prev_file",
    ReviewNextHunk = "next_hunk",
    ReviewPrevHunk = "prev_hunk",
  }) do
    vim.api.nvim_create_user_command(command, function()
      require("review")[action]()
    end, { desc = "Git review: " .. action })
  end
end
return M
