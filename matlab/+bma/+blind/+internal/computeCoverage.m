function c = computeCoverage(refs)
%COMPUTECOVERAGE Reference-reading coverage for the blind protocol.
%   complete = every reference has a verified reading note. `limited` entries
%   (citation-only or text-unavailable) are listed in blocking_ids until an
%   impossible/over_budget self-check issue covers them.
refs = bma.blind.internal.asStructList(refs);
total = numel(refs);
read = 0;
limited = 0;
pending = 0;
verified = 0;
noModeling = 0;
withClaims = 0;
depths = struct('full_text', 0, 'abstract_only', 0, 'citation_only', 0, 'none', 0);
blocking = {};
limitedReasons = {};
for k = 1:total
    r = refs{k};
    status = lower(strtrim(char(getStr(r, 'status', 'pending'))));
    depth = lower(strtrim(char(getStr(r, 'depth', ''))));
    if getBool(r, 'no_modeling_content', false)
        noModeling = noModeling + 1;
    end
    if double(getNum(r, 'claims_count', 0)) > 0
        withClaims = withClaims + 1;
    end
    if strcmp(status, 'read')
        read = read + 1;
        if logical(getBool(r, 'verified', false))
            verified = verified + 1;
        end
    elseif strcmp(status, 'limited')
        limited = limited + 1;
        blocking{end + 1} = char(getStr(r, 'id', sprintf('R%d', k))); %#ok<AGROW>
        limitedReasons{end + 1} = struct( ...
            'id', char(getStr(r, 'id', sprintf('R%d', k))), ...
            'reason', char(getStr(r, 'access_limited_reason', ''))); %#ok<AGROW>
    else
        pending = pending + 1;
        blocking{end + 1} = char(getStr(r, 'id', sprintf('R%d', k))); %#ok<AGROW>
    end
    if any(strcmp(depth, {'full_text', 'abstract_only', 'citation_only'}))
        depths.(depth) = depths.(depth) + 1;
    else
        depths.none = depths.none + 1;
    end
end
c = struct();
c.total = total;
c.read = read;
c.verified = verified;
c.limited = limited;
c.pending = pending;
c.no_modeling = noModeling;
c.with_claims = withClaims;
c.percent = round(100 * read / max(total, 1));
c.complete = total > 0 && read == total;
c.blocking_ids = blocking;
c.limited_reasons = limitedReasons;
c.depths = depths;
end

% ---------------------------------------------------------------------------
function v = getStr(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = char(string(s.(f)));
else
    v = d;
end
end

function v = getBool(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = logical(s.(f));
else
    v = d;
end
end

function v = getNum(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f)) && isnumeric(s.(f))
    v = double(s.(f));
else
    v = d;
end
end
