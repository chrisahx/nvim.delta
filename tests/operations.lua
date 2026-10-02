vim.opt.runtimepath:prepend(vim.fn.getcwd())
local review = require("review")
local git_module = require("review.git")
local passed = 0
local notifications = {}
local original_notify, original_select = vim.notify, vim.ui.select
vim.notify = function(message)
  notifications[#notifications + 1] = message
end
vim.ui.select = function(items, opts, callback)
  local choice = opts.prompt:find("Buffer only", 1, true) and 2 or 1
  callback(items[choice], choice)
end
local function eq(a, b)
  assert(vim.deep_equal(a, b), "expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a))
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    io.stderr:write(
      "FAIL " .. name .. "\n" .. err .. "\nNotifications: " .. vim.inspect(notifications) .. "\n"
    )
    vim.cmd("cquit 1")
  end
  passed = passed + 1
  print("PASS " .. name)
end
local function wait(fn)
  assert(vim.wait(5000, fn, 10), "async operation timed out")
end
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")
local function git(args)
  local argv = { "git", "-C", temp }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = false }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end
local function write(path, data)
  vim.fn.writefile(vim.split(data, "\n", { plain = true }), temp .. "/" .. path, "b")
end
local base = {}
for i = 1, 12 do
  base[i] = "line " .. i
end
local function contents(lines)
  return table.concat(lines, "\n") .. "\n"
end
local committed = vim.deepcopy(base)
committed[1] = "committed line 1"
git({ "init", "-b", "main" })
git({ "config", "user.name", "Tests" })
git({ "config", "user.email", "tests@example.com" })
write("source.txt", contents(base))
git({ "add", "." })
git({ "commit", "-m", "base" })
git({ "checkout", "-b", "feature" })
write("source.txt", contents(committed))
git({ "add", "." })
git({ "commit", "-m", "feature" })
vim.cmd.cd(vim.fn.fnameescape(temp))
review.setup({ base = "main", use_merge_base = false })
local function file(path)
  for _, f in ipairs(review.get_session().files) do
    if f.path == (path or "source.txt") then
      return f
    end
  end
end
local function reset(data, path)
  review.close()
  git({ "reset", "--hard", "HEAD" })
  git({ "clean", "-fd" })
  path = path or "source.txt"
  if data then
    write(path, data)
  end
  vim.cmd("edit! " .. vim.fn.fnameescape(temp .. "/" .. path))
  vim.cmd("edit!") -- Also reload an already-existing hidden buffer.
  review.start()
  wait(function()
    return review.get_session() and file(path) and file(path).fingerprint
  end)
  require("review.session").open((function()
    for i, f in ipairs(review.get_session().files) do
      if f.path == path then
        return i
      end
    end
  end)())
  wait(function()
    return file(path).fingerprint ~= nil
  end)
  notifications = {}
  return vim.api.nvim_get_current_buf()
end
local function action(name, row)
  if row then
    vim.api.nvim_win_set_cursor(0, { row, 0 })
  end
  review[name]()
  wait(function()
    return not review.get_session().operation
  end)
end
local function settle(predicate)
  wait(function()
    return file() and predicate(file())
  end)
end
local function signs(buf)
  local result = {}
  for _, mark in
    ipairs(
      vim.api.nvim_buf_get_extmarks(
        buf,
        require("review.decorations").namespace,
        0,
        -1,
        { details = true }
      )
    )
  do
    if mark[4].sign_text then
      result[mark[2]] = mark[4]
    end
  end
  return result
end
local function changed()
  local lines = vim.deepcopy(committed)
  lines[3], lines[10] = "working line 3", "working line 10"
  return lines
end

test("stage one hunk, leave disk and unrelated hunks untouched", function()
  local work = changed()
  local buf = reset(contents(work))
  eq(vim.fn.maparg("<leader>rs", "n", false, true).desc, "Review: stage_hunk")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.cmd("ReviewStageHunk")
  wait(function()
    return not review.get_session().operation
  end)
  local expected = vim.deepcopy(committed)
  expected[3] = work[3]
  eq(git({ "show", ":source.txt" }), contents(expected))
  eq(require("review.buffer").text(buf), contents(work))
  eq(require("review.index").read(temp .. "/source.txt"), contents(work))
  settle(function(f)
    return f.staged and f.unstaged
  end)
  eq(vim.bo[buf].modified, false)
  settle(function(f)
    return f.staged_rows and f.staged_rows.lines[2]
  end)
  eq(signs(buf)[2].sign_hl_group, "ReviewStagedSign")
  assert(signs(buf)[2].sign_text:find("┃", 1, true))
  eq(signs(buf)[9].sign_hl_group, "ReviewChangeSign")
  eq(signs(buf)[0].sign_hl_group, "ReviewChangeSign") -- committed, not staged
  action("unstage_hunk", 3)
  settle(function(f)
    return not f.staged and f.hunks[1] ~= nil
  end)
  eq(signs(buf)[2].sign_hl_group, "ReviewChangeSign")
end)

test("unstage a hunk at its working-buffer position after insertions", function()
  local work = changed()
  local buf = reset(contents(work))
  git({ "add", "source.txt" })
  local inserted = { "prefix 1", "prefix 2" }
  vim.list_extend(inserted, work)
  write("source.txt", contents(inserted))
  vim.cmd("edit!")
  review.refresh()
  settle(function(f)
    return f.staged and f.unstaged and f.hunks[1] ~= nil
  end)
  action("unstage_hunk", 12)
  local expected = vim.deepcopy(committed)
  expected[3] = work[3]
  eq(git({ "show", ":source.txt" }), contents(expected))
  eq(require("review.buffer").text(buf), contents(inserted))
  settle(function(f)
    return f.staged_rows and f.staged_rows.lines[4] and not f.staged_rows.lines[11]
  end)
  eq(signs(buf)[4].sign_hl_group, "ReviewStagedSign")
  eq(signs(buf)[11].sign_hl_group, "ReviewChangeSign")
end)

test("staged markers do not hide unsaved replacements on the same line", function()
  local buf = reset(contents(changed()))
  git({ "add", "source.txt" })
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "new unstaged edit" })
  review.refresh()
  settle(function(f)
    return f.staged_rows and f.staged_rows.lines[9]
  end)
  eq(signs(buf)[2].sign_hl_group, "ReviewChangeSign")
  eq(signs(buf)[9].sign_hl_group, "ReviewStagedSign")
end)

test("addition and deletion signs update when staged and unstaged", function()
  local added = vim.deepcopy(committed)
  added[#added + 1] = "new addition"
  local buf = reset(contents(added))
  eq(signs(buf)[12].sign_hl_group, "ReviewAddSign")
  action("stage_hunk", 13)
  settle(function(f)
    return f.staged_rows and f.staged_rows.lines[12]
  end)
  eq(signs(buf)[12].sign_hl_group, "ReviewStagedSign")
  action("unstage_hunk", 13)
  settle(function(f)
    return not f.staged and f.hunks[1]
  end)
  eq(signs(buf)[12].sign_hl_group, "ReviewAddSign")
  local deleted = vim.deepcopy(committed)
  table.remove(deleted)
  buf = reset(contents(deleted))
  eq(signs(buf)[10].sign_hl_group, "ReviewDeleteSign")
  action("stage_hunk", 11)
  settle(function(f)
    return f.staged_rows and f.staged_rows.deletions[10]
  end)
  eq(signs(buf)[10].sign_hl_group, "ReviewStagedSign")
  action("unstage_hunk", 11)
  settle(function(f)
    return not f.staged and f.hunks[1]
  end)
  eq(signs(buf)[10].sign_hl_group, "ReviewDeleteSign")
end)

test("refuse staging unsaved edits", function()
  local buf = reset(contents(changed()))
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "unsaved" })
  action("stage_hunk", 3)
  eq(git({ "show", ":source.txt" }), contents(committed))
  assert(notifications[#notifications]:find("Save the buffer", 1, true))
end)

test("discard restores index, preserves staged and other unsaved edits, supports undo", function()
  local work = changed()
  local buf = reset(contents(work))
  local staged = vim.deepcopy(committed)
  staged[3] = "staged line 3"
  write("source.txt", contents(staged))
  git({ "add", "source.txt" })
  write("source.txt", contents(work))
  vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "another unsaved edit" })
  local before = require("review.buffer").text(buf)
  action("discard_hunk", 3)
  eq(vim.api.nvim_buf_get_lines(buf, 2, 3, false), { "staged line 3" })
  eq(vim.api.nvim_buf_get_lines(buf, 4, 5, false), { "another unsaved edit" })
  eq(vim.api.nvim_buf_get_lines(buf, 9, 10, false), { "working line 10" })
  eq(git({ "show", ":source.txt" }), contents(staged))
  eq(require("review.index").read(temp .. "/source.txt"), contents(work))
  assert(vim.bo[buf].modified)
  vim.cmd("undo")
  eq(require("review.buffer").text(buf), before)
end)

test("review-base restore reverses committed code in buffer only", function()
  local buf = reset(contents(changed()))
  action("restore_base_hunk", 1)
  eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false), { "line 1" })
  eq(git({ "show", ":source.txt" }), contents(committed))
  eq(vim.api.nvim_buf_get_lines(buf, 2, 3, false), { "working line 3" })
  assert(vim.bo[buf].modified)
end)

test("cancel discard without changing anything", function()
  local buf = reset(contents(changed()))
  local before = require("review.buffer").text(buf)
  local select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    callback(items[1], 1)
  end
  action("discard_hunk", 3)
  vim.ui.select = select
  eq(require("review.buffer").text(buf), before)
  eq(vim.bo[buf].modified, false)
end)

test("confirmation rejects buffer changes and external index changes", function()
  local buf = reset(contents(changed()))
  local select = vim.ui.select
  local reply
  vim.ui.select = function(_, _, callback)
    reply = callback
  end
  review.discard_hunk()
  wait(function()
    return reply ~= nil
  end)
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "changed while confirming" })
  reply("Discard unstaged", 2)
  wait(function()
    return not review.get_session().operation
  end)
  eq(vim.api.nvim_buf_get_lines(buf, 2, 3, false), { "changed while confirming" })
  assert(notifications[#notifications]:find("changed", 1, true))
  reply = nil
  review.discard_hunk()
  wait(function()
    return reply ~= nil
  end)
  git({ "add", "source.txt" })
  reply("Discard unstaged", 2)
  wait(function()
    return not review.get_session().operation
  end)
  eq(vim.api.nvim_buf_get_lines(buf, 2, 3, false), { "changed while confirming" })
  assert(notifications[#notifications]:find("Git index changed", 1, true))
  vim.ui.select = select
end)

test("stage/unstage untracked files, quoted paths and no-newline files", function()
  for _, path in ipairs({ "new.txt", 'odd\t"\\name.txt' }) do
    local buf = reset("first\nlast", path)
    action("stage_hunk", 1)
    eq(git({ "show", ":" .. path }), "first\nlast")
    action("unstage_hunk", 1)
    eq(git({ "ls-files", "--", ":(literal)" .. path }), "")
    eq(require("review.buffer").text(buf), "first\nlast")
  end
end)

test("stage an intent-to-add file", function()
  reset("intent\n", "intent.txt")
  git({ "add", "--intent-to-add", "intent.txt" })
  action("stage_hunk", 1)
  eq(git({ "show", ":intent.txt" }), "intent\n")
end)

test("stage refuses an externally changed file behind a stale buffer", function()
  reset(contents(changed()))
  write("source.txt", "external change\n")
  action("stage_hunk", 3)
  eq(git({ "show", ":source.txt" }), contents(committed))
  assert(notifications[#notifications]:find("differs from the filesystem", 1, true))
end)

test("DOS/BOM text staging and discard preserve decoded buffer text", function()
  for _, item in ipairs({
    { "dos.txt", "first\r\nsecond\r\n" },
    { "bom.txt", "\239\187\191first\nsecond\n" },
  }) do
    local buf = reset(item[2], item[1])
    action("stage_hunk", 1)
    eq(git({ "show", ":" .. item[1] }), item[2])
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "changed" })
    action("discard_hunk", 2)
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "first", "second" })
    assert(vim.bo[buf].fileformat == "dos" or vim.bo[buf].bomb)
  end
end)

test("stage/unstage an empty file and an executable file", function()
  for _, item in ipairs({ { "empty.txt", "", "100644" }, { "run.sh", "echo hi\n", "100755" } }) do
    reset(item[2], item[1])
    if item[3] == "100755" then
      assert(vim.uv.fs_chmod(temp .. "/" .. item[1], 493))
    end
    action("stage_hunk", 1)
    eq(git({ "show", ":" .. item[1] }), item[2])
    assert(git({ "ls-files", "--stage", "--", item[1] }):find(item[3], 1, true))
    action("unstage_hunk", 1)
    eq(git({ "ls-files", "--", item[1] }), "")
  end
end)

test("respect existing Git index locks, release our own locks on errors", function()
  reset(contents(changed()))
  write(".git/index.lock", "occupied")
  action("stage_hunk", 3)
  eq(require("review.index").read(temp .. "/.git/index.lock"), "occupied")
  eq(git({ "show", ":source.txt" }), contents(committed))
  vim.fn.delete(temp .. "/.git/index.lock")
  local result, error, done
  local entry
  git_module.index_entry(temp, "source.txt", function(value)
    entry = value
  end)
  wait(function()
    return entry ~= nil
  end)
  require("review.index").apply(temp, "source.txt", entry, "invalid patch\n", false, function()
    return true
  end, function(value, err)
    result, error, done = value, err, true
  end)
  wait(function()
    return done
  end)
  eq(result, nil)
  assert(error)
  eq(vim.uv.fs_stat(temp .. "/.git/index.lock"), nil)
end)

test("stage and unstage a fully deleted file", function()
  reset(contents(changed()))
  vim.fn.delete(temp .. "/source.txt")
  review.refresh()
  settle(function(f)
    return f.status == "D"
  end)
  require("review.session").open(1)
  wait(function()
    return file().buf and vim.bo[file().buf].buftype == "nofile"
  end)
  action("stage_hunk")
  eq(git({ "ls-files", "--", "source.txt" }), "")
  action("unstage_hunk")
  eq(git({ "show", ":source.txt" }), contents(committed))
  eq(vim.uv.fs_stat(temp .. "/source.txt"), nil)
end)

test("EOF options follow undo, redo and alternate undo branches", function()
  local b, d = require("review.buffer"), require("review.diff")
  for _, item in ipairs({ { "a\n", "a" }, { "a", "a\n" }, { "", "a\n" } }) do
    local buf = reset(item[2], "eof.txt")
    local original_fixeol = vim.bo[buf].fixendofline
    b.revert(buf, d.compute(item[1], item[2])[1])
    eq(b.text(buf), item[1])
    vim.cmd("undo")
    eq(b.text(buf), item[2])
    eq(vim.bo[buf].fixendofline, original_fixeol)
    vim.cmd("redo")
    eq(b.text(buf), item[1])
    vim.cmd("undo")
    b.sync(buf)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "branch" })
    eq(b.text(buf), "branch" .. (item[2]:sub(-1) == "\n" and "\n" or ""))
  end
end)

test("stale stage selection cannot overwrite an external index update", function()
  reset(contents(changed()))
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  local select, reply, items = vim.ui.select
  vim.ui.select = function(values, _, callback)
    items, reply = values, callback
  end
  review.stage_hunk()
  wait(function()
    return reply ~= nil
  end)
  git({ "add", "source.txt" })
  reply(items[1], 1)
  wait(function()
    return not review.get_session().operation
  end)
  eq(git({ "show", ":source.txt" }), contents(changed()))
  eq(vim.uv.fs_stat(temp .. "/.git/index.lock"), nil)
  assert(notifications[#notifications]:find("Git index changed", 1, true))
  vim.ui.select = select
end)

test("closing a session aborts index publication and releases the lock", function()
  reset(contents(changed()))
  local run, reply = git_module.run
  git_module.run = function(root, args, callback, opts)
    if args[1] ~= "apply" then
      run(root, args, callback, opts)
      return
    end
    run(root, args, function(out, err)
      reply = function()
        callback(out, err)
      end
    end, opts)
  end
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  review.stage_hunk()
  wait(function()
    return reply ~= nil
  end)
  review.close()
  reply()
  wait(function()
    return vim.uv.fs_stat(temp .. "/.git/index.lock") == nil
  end)
  eq(git({ "show", ":source.txt" }), contents(committed))
  git_module.run = run
end)

test("index transactions work without an existing index", function()
  local root = temp .. "/unborn"
  vim.fn.mkdir(root, "p")
  assert(vim.system({ "git", "-C", root, "init" }):wait().code == 0)
  local patch = git_module.addition("new.txt", "new\n", false)
  local done, result, error
  require("review.index").apply(
    root,
    "new.txt",
    { oid = false, mode = false },
    patch.header .. require("review.diff").patch(patch.hunks[1]),
    false,
    function()
      return true
    end,
    function(ok, err)
      result, error, done = ok, err, true
    end
  )
  wait(function()
    return done
  end)
  assert(result, error)
  local blob = vim.system({ "git", "-C", root, "show", ":new.txt" }):wait()
  eq(blob.code, 0)
  eq(blob.stdout, "new\n")
  eq(vim.uv.fs_stat(root .. "/.git/index.lock"), nil)
  vim.fn.delete(root, "rf")
end)

test("stage transactions support split indexes", function()
  reset(contents(changed()))
  git({ "update-index", "--split-index" })
  action("stage_hunk", 3)
  local expected = vim.deepcopy(committed)
  expected[3] = "working line 3"
  eq(git({ "show", ":source.txt" }), contents(expected))
  git({ "update-index", "--no-split-index" })
end)

test("linked worktree staging does not touch the main worktree index", function()
  review.close()
  local worktree = temp .. "-worktree"
  git({ "worktree", "add", "-b", "other-worktree", worktree, "HEAD" })
  local patch = git_module.addition("linked.txt", "linked\n", false)
  local result, error, done
  require("review.index").apply(
    worktree,
    "linked.txt",
    { oid = false, mode = false },
    patch.header .. require("review.diff").patch(patch.hunks[1]),
    false,
    function()
      return true
    end,
    function(ok, err)
      result, error, done = ok, err, true
    end
  )
  wait(function()
    return done
  end)
  assert(result, error)
  local blob = vim.system({ "git", "-C", worktree, "show", ":linked.txt" }):wait()
  eq(blob.code, 0)
  eq(blob.stdout, "linked\n")
  eq(git({ "ls-files", "--", "linked.txt" }), "")
  git({ "worktree", "remove", "--force", worktree })
end)

test("discard handles first/last-line deletions, empty files and EOF newline", function()
  local diff = require("review.diff")
  for _, item in ipairs({
    { "a\nb\n", "b\n" },
    { "a\nb\n", "a\n" },
    { "", "a\n" },
    { "a", "a\n" },
    { "a\n", "a" },
    { "a\nb", "a\nc" },
    { "\n", "" },
  }) do
    local result = item[2]
    local hunks = diff.compute(item[1], item[2])
    for i = #hunks, 1, -1 do
      result = diff.revert(result, hunks[i])
    end
    eq(result, item[1])
  end
end)

review.close()
vim.notify, vim.ui.select = original_notify, original_select
vim.cmd.cd(vim.fn.fnameescape(vim.env.HOME or "/tmp"))
vim.fn.delete(temp, "rf")
print(string.format("%d hunk-operation tests passed", passed))
vim.cmd("qa!")
