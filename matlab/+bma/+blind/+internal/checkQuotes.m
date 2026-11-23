function chk = checkQuotes(text, claims)
%CHECKQUOTES Verify that each reference-note quote occurs in the source text.
%   chk = bma.blind.internal.checkQuotes(text, claims)
%
%   Matching is whitespace/quote/dash normalized because PDF extraction breaks
%   lines and uses typographic punctuation. Quotes shorter than 6 chars are
%   rejected rather than accepted on a weak match.
%
%   Returns: checked, found, results{claim_index, quote, found, chars}.
chk = struct('checked', 0, 'found', 0, 'results', {{}});
claims = bma.blind.internal.asStructList(claims);
t = bma.blind.internal.normalizeQuoteText(text);
tHyph = regexprep(t, '-\s+', '');
tNows = regexprep(t, '\s+', '');
for k = 1:numel(claims)
    claim = claims{k};
    q = '';
    if isstruct(claim) && isfield(claim, 'quote') && ~isempty(claim.quote)
        q = char(string(claim.quote));
    end
    qn = bma.blind.internal.normalizeQuoteText(q);
    qHyph = regexprep(qn, '-\s+', '');
    qNows = regexprep(qn, '\s+', '');
    ok = false;
    if numel(qn) >= 6
        ok = containsAny(t, tHyph, tNows, qn, qHyph, qNows);
    end
    chk.checked = chk.checked + 1;
    if ok
        chk.found = chk.found + 1;
    end
    chk.results{end + 1} = struct('claim_index', k, 'quote', q, ...
        'found', ok, 'chars', numel(qn));
end
end

% ---------------------------------------------------------------------------
function tf = containsAny(t, tHyph, tNows, qn, qHyph, qNows)
tf = false;
if isempty(qn)
    return
end
tf = ~isempty(strfind(t, qn)) || ~isempty(strfind(tNows, qNows));
if tf
    return
end
tf = ~isempty(strfind(tHyph, qHyph)) || ~isempty(strfind(tNows, qHyph)) || ...
    ~isempty(strfind(tHyph, qNows));
end
