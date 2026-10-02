local M = {}
function M.register()
  vim.api.nvim_create_user_command("Delta", function(args)
    require("delta").start(args.args ~= "" and args.args or nil)
  end, { nargs = "?", desc = "Delta: compare working tree against a Git base" })
  for command, action in pairs({
    DeltaClose = "close",
    DeltaRefresh = "refresh",
    DeltaToggleReviewed = "toggle_reviewed",
    DeltaMarkReviewed = "mark_reviewed",
    DeltaMarkUnreviewed = "mark_unreviewed",
    DeltaNextFile = "next_file",
    DeltaPrevFile = "prev_file",
    DeltaNextHunk = "next_hunk",
    DeltaPrevHunk = "prev_hunk",
    DeltaStageHunk = "stage_hunk",
    DeltaUnstageHunk = "unstage_hunk",
    DeltaDiscardHunk = "discard_hunk",
    DeltaRestoreBaseHunk = "restore_base_hunk",
  }) do
    vim.api.nvim_create_user_command(command, function()
      require("delta")[action]()
    end, { desc = "Git delta: " .. action })
  end
end
return M
