-- word_diff.lua — local word-level diff (LCS), no AI call.
-- Public API:
--   M.tokenize(s)       -> { tokens }  words, single punctuation marks, whitespace runs
--   M.diff(a, b)        -> segments, stats
--       segments: ordered { op = "eq" | "del" | "ins", text = "..." }
--       stats:    { changes = <number of edit groups>, changed_ratio = 0..1 }

local M = {}

-- Above this many DP cells the middle section is shown as one replacement
-- instead of running LCS (keeps huge rewrites from stalling Hammerspoon).
local MAX_CELLS = 250000

local function is_space(c) return c:match("^%s$") ~= nil end
-- Bytes >= 0x80 (UTF-8, e.g. Urdu) are neither %s nor %p, so they count as word chars.
local function is_word(c) return not c:match("^[%s%p]$") end

function M.tokenize(s)
    local tokens, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        local j = i
        if is_space(c) then
            while j < n and is_space(s:sub(j + 1, j + 1)) do j = j + 1 end
        elseif is_word(c) then
            -- A word may contain an apostrophe or hyphen between word chars: don't, e-mail.
            while j < n do
                local nx = s:sub(j + 1, j + 1)
                if is_word(nx) then
                    j = j + 1
                elseif (nx == "'" or nx == "-") and j + 2 <= n and is_word(s:sub(j + 2, j + 2)) then
                    j = j + 2
                else
                    break
                end
            end
        end
        table.insert(tokens, s:sub(i, j))
        i = j + 1
    end
    return tokens
end

local function lcs_ops(a, b, a0, a1, b0, b1, ops)
    local n, m = a1 - a0 + 1, b1 - b0 + 1
    if n <= 0 then
        for j = b0, b1 do table.insert(ops, { "ins", b[j] }) end
        return
    end
    if m <= 0 then
        for i = a0, a1 do table.insert(ops, { "del", a[i] }) end
        return
    end
    if n * m > MAX_CELLS then
        for i = a0, a1 do table.insert(ops, { "del", a[i] }) end
        for j = b0, b1 do table.insert(ops, { "ins", b[j] }) end
        return
    end

    -- dp[i][j] = LCS length of a[a0+i-1 ..] and b[b0+j-1 ..] (suffix form, so we can walk forward)
    local dp = {}
    for i = n + 1, 1, -1 do
        local row, below = {}, dp[i + 1]
        for j = m + 1, 1, -1 do
            if i > n or j > m then
                row[j] = 0
            elseif a[a0 + i - 1] == b[b0 + j - 1] then
                row[j] = below[j + 1] + 1
            else
                local d, r = below[j], row[j + 1]
                row[j] = d > r and d or r
            end
        end
        dp[i] = row
    end

    local i, j = 1, 1
    while i <= n and j <= m do
        if a[a0 + i - 1] == b[b0 + j - 1] then
            table.insert(ops, { "eq", a[a0 + i - 1] }); i = i + 1; j = j + 1
        elseif dp[i + 1][j] >= dp[i][j + 1] then
            table.insert(ops, { "del", a[a0 + i - 1] }); i = i + 1
        else
            table.insert(ops, { "ins", b[b0 + j - 1] }); j = j + 1
        end
    end
    while i <= n do table.insert(ops, { "del", a[a0 + i - 1] }); i = i + 1 end
    while j <= m do table.insert(ops, { "ins", b[b0 + j - 1] }); j = j + 1 end
end

-- Turn the op stream into readable segments: whitespace sandwiched between two
-- edits joins the edit, and each edit group becomes one del followed by one ins
-- ("~~ton queue~~ **to queues**" rather than an alternating mess).
local function group(ops)
    local segs, k, groups = {}, 1, 0
    local function push(op, text)
        if text == "" then return end
        local last = segs[#segs]
        if last and last.op == op then last.text = last.text .. text
        else table.insert(segs, { op = op, text = text }) end
    end
    while k <= #ops do
        if ops[k][1] == "eq" then
            push("eq", ops[k][2]); k = k + 1
        else
            local del, ins = {}, {}
            while k <= #ops do
                local op, text = ops[k][1], ops[k][2]
                if op == "del" then table.insert(del, text); k = k + 1
                elseif op == "ins" then table.insert(ins, text); k = k + 1
                elseif text:match("^%s+$") and ops[k + 1] and ops[k + 1][1] ~= "eq" then
                    table.insert(del, text); table.insert(ins, text); k = k + 1
                else break end
            end
            groups = groups + 1
            push("del", table.concat(del))
            push("ins", table.concat(ins))
        end
    end
    return segs, groups
end

function M.diff(a_text, b_text)
    local a, b = M.tokenize(a_text or ""), M.tokenize(b_text or "")

    -- Trim the common prefix and suffix before LCS.
    local pre = 0
    while pre < #a and pre < #b and a[pre + 1] == b[pre + 1] do pre = pre + 1 end
    local suf = 0
    while suf < #a - pre and suf < #b - pre and a[#a - suf] == b[#b - suf] do suf = suf + 1 end

    local ops = {}
    for i = 1, pre do table.insert(ops, { "eq", a[i] }) end
    lcs_ops(a, b, pre + 1, #a - suf, pre + 1, #b - suf, ops)
    for i = #a - suf + 1, #a do table.insert(ops, { "eq", a[i] }) end

    local changed, total = 0, 0
    for _, op in ipairs(ops) do
        if not op[2]:match("^%s+$") then
            total = total + 1
            if op[1] ~= "eq" then changed = changed + 1 end
        end
    end

    local segs, groups = group(ops)
    return segs, { changes = groups, changed_ratio = total > 0 and changed / total or 0 }
end

return M
