function s = issueStats(issues)
%ISSUESTATS Count self-check issues by status and list the relevant ids.
%   s = bma.blind.internal.issueStats(issues)
issues = bma.blind.internal.asStructList(issues);
s = struct('total', numel(issues), 'open', 0, 'fixed', 0, ...
    'impossible', 0, 'over_budget', 0, 'open_ids', {{}}, ...
    'terminal_ids', {{}});
for k = 1:numel(issues)
    st = lower(strtrim(char(getStr(issues{k}, 'status', 'open'))));
    id = char(getStr(issues{k}, 'id', sprintf('I%d', k)));
    switch st
        case 'open'
            s.open = s.open + 1;
            s.open_ids{end + 1} = id;
        case 'fixed'
            s.fixed = s.fixed + 1;
            s.terminal_ids{end + 1} = id;
        case 'impossible'
            s.impossible = s.impossible + 1;
            s.terminal_ids{end + 1} = id;
        case 'over_budget'
            s.over_budget = s.over_budget + 1;
            s.terminal_ids{end + 1} = id;
        otherwise
            s.open = s.open + 1;
            s.open_ids{end + 1} = id;
    end
end
end

% ---------------------------------------------------------------------------
function v = getStr(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = char(string(s.(f)));
else
    v = d;
end
end
