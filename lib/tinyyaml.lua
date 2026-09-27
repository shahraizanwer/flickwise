-- tinyyaml.lua — pure-Lua YAML subset parser
-- Based on lua-tinyyaml by peposso (MIT License)
-- https://github.com/peposso/lua-tinyyaml
--
-- MIT License
-- Copyright (c) 2017 peposso
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.

local M = {}

-- ── helpers ───────────────────────────────────────────────────────────────────

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function starts(s, prefix)
    return s:sub(1, #prefix) == prefix
end

local function indent_of(line)
    return #(line:match("^( *)") or "")
end

-- Parse a plain scalar to its Lua type
local function scalar(s)
    if s == "~" or s == "null" or s == "Null" or s == "NULL" then return nil end
    if s == "true"  or s == "True"  or s == "TRUE"  then return true  end
    if s == "false" or s == "False" or s == "FALSE" then return false end
    if s:match("^[-+]?%d+$")                         then return tonumber(s) end
    if s:match("^0x%x+$")                            then return tonumber(s, 16) end
    if s:match("^[-+]?%d*%.%d+([eE][-+]?%d+)?$")    then return tonumber(s) end
    return s
end

-- Unescape a double-quoted string (after stripping outer quotes)
local function unescape_dq(s)
    return (s
        :gsub("\\n",  "\n")
        :gsub("\\r",  "\r")
        :gsub("\\t",  "\t")
        :gsub('\\"',  '"')
        :gsub("\\\\", "\\"))
end

-- Parse a single value token (scalar / quoted string / inline flow sequence)
local function parse_value_token(s)
    s = trim(s)
    if s == "" then return nil end

    -- double-quoted
    if s:sub(1,1) == '"' then
        return unescape_dq(s:match('^"(.-)"$') or s:sub(2,-2))
    end

    -- single-quoted
    if s:sub(1,1) == "'" then
        return s:match("^'(.-)'$") or s:sub(2,-2)
    end

    -- inline flow sequence  ["a", "b", "c"]
    if s:sub(1,1) == "[" and s:sub(-1) == "]" then
        local inner = s:sub(2,-2)
        local result = {}
        -- split on commas outside quotes
        local cur = ""
        local in_q, q_char = false, nil
        for i = 1, #inner do
            local c = inner:sub(i,i)
            if in_q then
                if c == q_char then in_q = false
                elseif c == "\\" then -- skip next char handled below
                end
                cur = cur .. c
            elseif c == '"' or c == "'" then
                in_q, q_char = true, c
                cur = cur .. c
            elseif c == "," then
                table.insert(result, parse_value_token(cur))
                cur = ""
            else
                cur = cur .. c
            end
        end
        if trim(cur) ~= "" then
            table.insert(result, parse_value_token(cur))
        end
        return result
    end

    -- inline flow mapping  {k: v, ...}  (simple support)
    if s:sub(1,1) == "{" and s:sub(-1) == "}" then
        return {}   -- empty or unsupported — return empty table
    end

    return scalar(s)
end

-- ── block scalar collector ────────────────────────────────────────────────────

-- Reads lines[i..] that are indented >= block_indent.
-- Returns the assembled string and the next line index.
local function collect_block_scalar(lines, start_i, block_indent, fold)
    local parts  = {}
    local i      = start_i
    while i <= #lines do
        local line = lines[i]
        local trimmed = trim(line)
        if trimmed == "" then
            table.insert(parts, "")
            i = i + 1
        else
            local ind = indent_of(line)
            if ind < block_indent then break end
            table.insert(parts, line:sub(block_indent + 1))
            i = i + 1
        end
    end
    -- strip trailing blank entries
    while #parts > 0 and parts[#parts] == "" do table.remove(parts) end

    local sep = fold and " " or "\n"
    return table.concat(parts, sep) .. "\n", i
end

-- ── main parser ───────────────────────────────────────────────────────────────

local function parse_lines(lines)
    local root  = {}
    -- stack entries: { indent, obj, is_seq }
    local stack = {{ indent = -1, obj = root, is_seq = false }}

    local function current() return stack[#stack] end

    local function pop_to(ind)
        while #stack > 1 and stack[#stack].indent >= ind do
            table.remove(stack)
        end
    end

    local i = 1
    while i <= #lines do
        local raw  = lines[i]
        local line = raw:gsub("\t", "    ")           -- expand tabs
        local cont = trim(line)

        -- skip blank lines and full-line comments
        if cont == "" or cont:sub(1,1) == "#" then
            i = i + 1
            goto continue
        end

        -- strip trailing inline comment (outside quotes)
        do
            local in_q = false
            local q_c  = nil
            for pos = 1, #cont do
                local c = cont:sub(pos,pos)
                if in_q then
                    if c == q_c then in_q = false end
                elseif c == '"' or c == "'" then
                    in_q, q_c = true, c
                elseif c == "#" and pos > 1 and cont:sub(pos-1,pos-1) == " " then
                    cont = trim(cont:sub(1, pos-1))
                    break
                end
            end
        end

        local ind = indent_of(line)

        pop_to(ind)

        local par = current()

        -- ── sequence item ─────────────────────────────────────────────────
        if starts(cont, "- ") or cont == "-" then
            local rest = (cont == "-") and "" or trim(cont:sub(3))

            if rest == "" then
                -- nested block mapping or sequence follows
                local new_obj = {}
                table.insert(par.obj, new_obj)
                table.insert(stack, { indent = ind, obj = new_obj, is_seq = false })
                i = i + 1
                goto continue
            end

            -- inline key:value as first field of a mapping-in-sequence
            local k2, v2 = rest:match("^([^:]+):%s*(.*)")
            if k2 and not rest:sub(1,1):match('["\']') then
                k2 = trim(k2)
                v2 = trim(v2)
                local new_obj = {}
                table.insert(par.obj, new_obj)
                table.insert(stack, { indent = ind, obj = new_obj, is_seq = false })

                if v2 == "" or v2 == "|" or v2 == ">" then
                    local fold   = (v2 == ">")
                    local bi     = (lines[i+1] and indent_of(lines[i+1]:gsub("\t","    "))) or (ind + 2)
                    local text, ni = collect_block_scalar(lines, i + 1, bi, fold)
                    new_obj[k2]  = text
                    i            = ni
                    goto continue
                end
                new_obj[k2] = parse_value_token(v2)
                i = i + 1
                goto continue
            end

            -- plain scalar item
            table.insert(par.obj, parse_value_token(rest))
            i = i + 1
            goto continue
        end

        -- ── mapping key:value ─────────────────────────────────────────────
        do
            local k, v = cont:match("^([^:]+):%s*(.*)")
            if k then
                k = trim(k)
                -- strip quotes from key
                if k:sub(1,1) == '"' then
                    k = unescape_dq(k:match('^"(.-)"$') or k:sub(2,-2))
                elseif k:sub(1,1) == "'" then
                    k = k:match("^'(.-)'$") or k:sub(2,-2)
                end
                v = trim(v or "")

                if v == "" or v == "|" or v == ">" then
                    -- peek at next non-blank line to determine block vs nested
                    local peek_i = i + 1
                    while peek_i <= #lines and trim(lines[peek_i]) == "" do peek_i = peek_i + 1 end

                    if v == "|" or v == ">" then
                        -- block scalar
                        local fold  = (v == ">")
                        local bi    = (lines[peek_i] and indent_of(lines[peek_i]:gsub("\t","    "))) or (ind + 2)
                        local text, ni = collect_block_scalar(lines, i + 1, bi, fold)
                        par.obj[k]  = text
                        i           = ni
                        goto continue
                    end

                    -- empty value — peek if next is seq or mapping
                    if peek_i <= #lines then
                        local next_cont = trim(lines[peek_i]:gsub("\t","    "))
                        local next_ind  = indent_of(lines[peek_i]:gsub("\t","    "))
                        if next_ind > ind then
                            if starts(next_cont, "- ") or next_cont == "-" then
                                local new_list = {}
                                par.obj[k] = new_list
                                table.insert(stack, { indent = ind, obj = new_list, is_seq = true })
                            else
                                local new_obj = {}
                                par.obj[k] = new_obj
                                table.insert(stack, { indent = ind, obj = new_obj, is_seq = false })
                            end
                            i = i + 1
                            goto continue
                        end
                    end
                    par.obj[k] = nil
                    i = i + 1
                    goto continue
                end

                par.obj[k] = parse_value_token(v)
                i = i + 1
                goto continue
            end
        end

        -- unrecognised line — skip
        i = i + 1
        ::continue::
    end

    return root
end

-- ── public ────────────────────────────────────────────────────────────────────

function M.parse(yaml_str)
    -- normalise line endings
    yaml_str = yaml_str:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    for line in (yaml_str .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end
    local ok, result = pcall(parse_lines, lines)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

return M
