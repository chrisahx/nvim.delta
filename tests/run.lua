vim.opt.runtimepath:prepend(vim.fn.getcwd())
local passed = 0
local function eq(actual, expected)
  assert(
    vim.deep_equal(actual, expected),
    "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
  )
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    io.stderr:write("FAIL " .. name .. "\n" .. err .. "\n")
    vim.cmd("cquit 1")
  end
  passed = passed + 1
  print("PASS " .. name)
end
local diff = require("delta.diff")
local cases = {
  { "simple addition", "a\n", "a\nb\n", 1, 0, 1 },
  { "simple deletion", "a\nb\nc\n", "a\nc\n", 1, 1, 0 },
  { "modification", "a\nb\n", "a\nc\n", 1, 1, 1 },
  { "multiple hunks", "a\nb\nc\nd\ne\n", "A\nb\nc\nd\nE\n", 2, 1, 1 },
  { "insertion at first line", "b\n", "a\nb\n", 1, 0, 1 },
  { "deletion at first line", "a\nb\n", "b\n", 1, 1, 0 },
  { "insertion at EOF", "a\n", "a\nb\n", 1, 0, 1 },
  { "deletion at EOF", "a\nb\n", "a\n", 1, 1, 0 },
  { "added file", "", "a\nb\n", 1, 0, 2 },
  { "deleted file", "a\nb\n", "", 1, 2, 0 },
  { "empty file", "", "", 0 },
}
for _, case in ipairs(cases) do
  test(case[1], function()
    local hunks = diff.compute(case[2], case[3])
    eq(#hunks, case[4])
    if hunks[1] then
      eq(hunks[1].old_count, case[5])
      eq(hunks[1].new_count, case[6])
    end
  end)
end

test("zero counts, omitted counts, context, no newline", function()
  local hunks = diff.parse(
    "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1,4 @@\n+a\n+b\n+c\n+d\n@@ -7 +8 @@\n-old\n+new\n\\ No newline at end of file\n@@ -10,2 +11,2 @@\n context\n-a\n+b\n"
  )
  eq(#hunks, 3)
  eq(hunks[1].old_count, 0)
  eq(hunks[1].new_count, 4)
  eq(hunks[2].new_count, 1)
  eq(hunks[2].lines[2].no_newline, true)
  eq(hunks[3].lines[1].kind, "context")
end)

test("file headers cannot become hunk lines", function()
  local hunks = diff.parse(
    "@@ -1 +1 @@\n-old\n+new\ndiff --git a/y b/y\n--- a/y\n+++ b/y\n@@ -0,0 +1 @@\n+added\n"
  )
  eq(#hunks, 2)
  eq(#hunks[1].lines, 2)
  eq(hunks[2].lines[1].text, "added")
end)

test("binary content", function()
  local hunks, binary = diff.compute("a\0b", "c")
  eq(hunks, {})
  eq(binary, true)
end)

test("deleted virtual line anchors and nonmutation", function()
  local dec = require("delta.decorations")
  local buf = vim.api.nvim_create_buf(false, true)
  for _, case in ipairs({
    { "a\nb\n", "b\n", 0, true },
    { "a\nb\nc\n", "a\nc\n", 1, true },
    { "a\nb\n", "a\n", 0, false },
    { "a\n", "", 0, true },
  }) do
    local lines = vim.split(case[2]:gsub("\n$", ""), "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    dec.apply(buf, diff.compute(case[1], case[2]))
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
    local marks = vim.api.nvim_buf_get_extmarks(buf, dec.namespace, 0, -1, { details = true })
    eq(#marks, 1)
    eq(marks[1][2], case[3])
    eq(marks[1][4].virt_lines_above, case[4])
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("staged rows track insertions and conservatively handle mixed deletions", function()
  local staging = require("delta.staging")
  local rows = staging.rows(
    diff.compute("a\n", "a\nb\nc\n"),
    diff.compute("a\nb\nc\n", "X\na\nb\nnew\nc\n"),
    5
  )
  eq(rows.lines, { [2] = true, [4] = true })
  for _, case in ipairs({
    { "old\na\n", "a\n", "a\n", { [0] = true } },
    { "old\na\n", "a\n", "new\na\n", {} },
    { "a\nb\n", "a\n", "a\n", { [0] = true } },
    { "a\nb\n", "a\n", "", {} },
  }) do
    rows = staging.rows(diff.compute(case[1], case[2]), diff.compute(case[2], case[3]), 1)
    eq(rows.deletions, case[4])
  end
end)

local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")
local function git(args)
  local cmd = { "git", "-C", temp }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end
local function write(path, lines)
  vim.fn.writefile(lines, temp .. "/" .. path)
end
local function wait(fn)
  assert(vim.wait(5000, fn, 10), "timed out waiting for async operation")
end
local delta = require("delta")
local function session()
  return delta.get_session()
end
local function find(path)
  for i, file in ipairs(session().files) do
    if file.path == path then
      return file, i
    end
  end
end

test("Git integration: staged, unstaged, added, deleted, untracked, literal paths", function()
  git({ "init", "-b", "main" })
  git({ "config", "user.email", "test@example.com" })
  git({ "config", "user.name", "Test" })
  write("source.lua", { "local old = 1", "return old" })
  write("deleted.lua", { "return 'deleted'" })
  write("odd\tname.lua", { "return 1" })
  git({ "add", "." })
  git({ "commit", "-m", "base" })
  write("source.lua", { "local staged = 2", "return staged" })
  git({ "add", "source.lua" })
  write("source.lua", { "local current = 3", "return current" })
  write("added.lua", { "return 'added'" })
  git({ "add", "added.lua" })
  write("untracked.lua", { "return 'untracked'" })
  write("odd\tname.lua", { "return 2" })
  vim.fn.delete(temp .. "/deleted.lua")
  vim.cmd.cd(vim.fn.fnameescape(temp))
  delta.setup({ base = "main", use_merge_base = false })
  delta.start()
  wait(function()
    return session() and #session().files == 5
  end)
  eq(find("source.lua").status, "M")
  eq(find("added.lua").status, "A")
  eq(find("deleted.lua").status, "D")
  eq(find("untracked.lua").status, "?")
  assert(find("odd\tname.lua"))
end)

test("real buffers, refresh after edits, review state, navigation, cleanup", function()
  local file, index = find("source.lua")
  local buf = vim.fn.bufadd(temp .. "/source.lua")
  vim.fn.bufload(buf)
  vim.keymap.set("n", "]h", "<Nop>", { buffer = buf, desc = "existing mapping" })
  require("delta.session").open(index)
  wait(function()
    return #file.hunks > 0
  end)
  eq(vim.api.nvim_get_current_buf(), buf)
  eq(vim.bo[buf].buftype, "")
  eq(vim.bo[buf].modifiable, true)
  eq(file.hunks[1].lines[1].text, "local old = 1")
  delta.mark_reviewed()
  eq(file.reviewed, true)
  delta.toggle_reviewed()
  eq(file.reviewed, false)
  delta.mark_reviewed()
  eq(delta.progress().reviewed, 1)
  delta.next_hunk()
  delta.prev_hunk()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "local better = 4" })
  delta.refresh()
  wait(function()
    local f = find("source.lua")
    return f and f.hunks[1] and f.hunks[1].lines[3].text == "local better = 4"
  end)
  eq(find("source.lua").reviewed, false)
  vim.cmd.write()
  wait(function()
    return find("source.lua").signature ~= file.signature
  end)
  local marks =
    vim.api.nvim_buf_get_extmarks(buf, require("delta.decorations").namespace, 0, -1, {})
  assert(#marks > 0)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local old = 1", "return old" })
  vim.cmd.write()
  wait(function()
    return not find("source.lua")
  end)
  eq(#session().files, 4)
  -- A previously unchanged filesystem file becomes changed and is discovered on save.
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "local another = 5" })
  vim.cmd.write()
  wait(function()
    return find("source.lua") and #find("source.lua").hunks > 0
  end)
  delta.next_file()
  delta.prev_file()
  delta.close()
  eq(session(), nil)
  eq(vim.api.nvim_buf_is_valid(buf), true)
  eq(#vim.api.nvim_buf_get_extmarks(buf, require("delta.decorations").namespace, 0, -1, {}), 0)
  vim.api.nvim_buf_call(buf, function()
    eq(vim.fn.maparg("]h", "n", false, true).desc, "existing mapping")
  end)
end)

test("deleted file exception and async cancellation", function()
  delta.start("main")
  wait(function()
    return session() ~= nil
  end)
  local file, index = find("deleted.lua")
  require("delta.session").open(index)
  wait(function()
    return file.buf ~= nil
  end)
  eq(vim.bo[file.buf].buftype, "nofile")
  eq(vim.bo[file.buf].modifiable, false)
  eq(vim.api.nvim_buf_get_lines(file.buf, 0, -1, false), { "return 'deleted'" })
  delta.next_hunk()
  local deleted_buf = file.buf
  local orphan = vim.fn.bufadd(temp .. "/deleted.lua")
  vim.fn.bufload(orphan)
  vim.api.nvim_win_set_buf(session().source_win, orphan)
  eq(file.buf, deleted_buf)
  require("delta.session").open(index)
  eq(vim.api.nvim_get_current_buf(), deleted_buf)
  delta.close()
  eq(vim.api.nvim_buf_is_valid(deleted_buf), false)
  delta.start("main")
  delta.close()
  vim.wait(200, function()
    return false
  end)
  eq(session(), nil)
end)

test("late content callbacks cannot resurrect a removed overlay", function()
  delta.start("main")
  wait(function()
    return session() ~= nil
  end)
  local git_module = require("delta.git")
  local original, delayed = git_module.content, {}
  git_module.content = function(root, commit, file, callback)
    if file.path ~= "source.lua" then
      original(root, commit, file, callback)
      return
    end
    original(root, commit, file, function(old, err)
      delayed[#delayed + 1] = function()
        callback(old, err)
      end
    end)
  end
  local file, index = find("source.lua")
  require("delta.session").open(index)
  wait(function()
    return #delayed > 0
  end)
  write("source.lua", { "local old = 1", "return old" })
  delta.refresh()
  wait(function()
    return not find("source.lua")
  end)
  for _, callback in ipairs(delayed) do
    callback()
  end
  eq(
    #vim.api.nvim_buf_get_extmarks(file.buf, require("delta.decorations").namespace, 0, -1, {}),
    0
  )
  git_module.content = original
  delta.close()
end)

test("real empty file versus one blank line and no final newline", function()
  write("blank.lua", { "" })
  write("empty.lua", {})
  vim.fn.writefile({ "return 7" }, temp .. "/noeol.lua", "b")
  delta.start("main")
  wait(function()
    return session() ~= nil
  end)
  for _, path in ipairs({ "blank.lua", "empty.lua", "noeol.lua" }) do
    local file, index = find(path)
    require("delta.session").open(index)
    wait(function()
      return file.fingerprint ~= nil
    end)
    if path == "empty.lua" then
      eq(#file.hunks, 0)
    elseif path == "blank.lua" then
      eq(file.hunks[1].new_count, 1)
      eq(file.hunks[1].lines[1].text, "")
    else
      eq(file.hunks[1].lines[1].no_newline, true)
    end
  end
  delta.close()
end)

test("base resolution, merge-base, invalid revision and repository errors", function()
  git({ "reset", "--hard", "HEAD" })
  git({ "clean", "-fd" })
  local ancestor = git({ "rev-parse", "HEAD" }):gsub("%s+$", "")
  git({ "checkout", "-b", "feature" })
  write("source.lua", { "return 'feature'" })
  git({ "add", "." })
  git({ "commit", "-m", "feature" })
  git({ "checkout", "main" })
  write("source.lua", { "return 'main'" })
  git({ "add", "." })
  git({ "commit", "-m", "main" })
  local main = git({ "rev-parse", "HEAD" }):gsub("%s+$", "")
  git({ "checkout", "feature" })
  local result, error, done
  require("delta.git").resolve(temp, "main", true, function(value, err)
    result, error, done = value, err, true
  end)
  wait(function()
    return done
  end)
  eq(error, nil)
  eq(result.commit, ancestor)
  done = false
  require("delta.git").resolve(temp, nil, false, function(value, err)
    result, error, done = value, err, true
  end)
  wait(function()
    return done
  end)
  eq(result.name, "main")
  eq(result.commit, main)
  done = false
  require("delta.git").resolve(temp, "--invalid-revision", false, function(value, err)
    result, error, done = value, err, true
  end)
  wait(function()
    return done
  end)
  eq(result, nil)
  assert(error:find("Invalid base revision", 1, true))
  done = false
  require("delta.git").root(vim.fs.dirname(temp), function(value, err)
    result, error, done = value, err, true
  end)
  wait(function()
    return done
  end)
  eq(result, nil)
  assert(error:find("Not inside a Git repository", 1, true))
end)

test("unresolved conflicts are rejected", function()
  local merged = vim.system({ "git", "-C", temp, "merge", "main" }):wait()
  assert(merged.code ~= 0)
  local result, error, done
  require("delta.git").files(temp, "main", function(value, err)
    result, error, done = value, err, true
  end)
  wait(function()
    return done
  end)
  eq(result, nil)
  assert(error:find("Resolve merge conflicts", 1, true))
end)

vim.cmd.cd(vim.fn.fnameescape(vim.env.HOME or "/tmp"))
vim.fn.delete(temp, "rf")
print(string.format("%d tests passed", passed))
vim.cmd("qa!")
