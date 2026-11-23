function t = normalizeQuoteText(t)
%NORMALIZEQUOTETEXT Normalize text for verbatim quote matching.
%   Lowercases, unifies typographic quotes/dashes/spaces, removes soft hyphens
%   and zero-width characters, and collapses whitespace. Used only for
%   verification; the stored quote remains exactly what the agent supplied.
if isempty(t)
    t = '';
    return
end
t = lower(char(t));
t = replaceChars(t, [8216 8217 8218 8219 8242 65287], '''');
t = replaceChars(t, [8220 8221 8222 8243 65282], '"');
t = replaceChars(t, [8211 8212 8213 8722], '-');
t = replaceChars(t, [160 8201 8202 8239 8288 12288], ' ');
t = replaceChars(t, [173 8203 8204 65279], '');
t = regexprep(t, '\s+', ' ');
t = strtrim(t);
end

% ---------------------------------------------------------------------------
function t = replaceChars(t, codes, repl)
for c = codes
    t(t == char(c)) = repl;
end
end
