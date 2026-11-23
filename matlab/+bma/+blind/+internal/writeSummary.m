function file = writeSummary(workDir, runDir, p, st)
%WRITESUMMARY Write the blind-protocol section for the final report.
%   file = bma.blind.internal.writeSummary(workDir, runDir, p, st)
%   Returns the absolute path; the caller stores its work-relative form.
file = fullfile(runDir, 'blind', 'blind_summary.md');
cov = st.coverage;
issues = bma.blind.internal.asStructList(p.selfcheck.issues);
q = p.question;
lines = {};
lines{end + 1} = '# 盲建模协议与自检记录（BLIND-LIT）';
lines{end + 1} = '';
lines{end + 1} = ['- 主文献：' char(string(p.primary.title))];
lines{end + 1} = ['- 主文献文件：`' char(string(p.primary.source_rel)) '`'];
lines{end + 1} = ['- 主文献 SHA-256：`' char(string(p.primary.sha256)) '`'];
lines{end + 1} = sprintf('- 摘要来源：%s（置信度 %s，%d 字符）', ...
    char(string(p.primary.abstract.source)), ...
    char(string(p.primary.abstract.confidence)), ...
    round(double(p.primary.abstract.chars)));
lines{end + 1} = '- 封印状态：建模期间未读取主文献全文、图、表；仅使用摘要与参考文献。';
lines{end + 1} = '';
lines{end + 1} = '## 建模问题与成功判据';
lines{end + 1} = '';
if isstruct(q) && ~isempty(strtrim(char(getStr(q, 'question', ''))))
    lines{end + 1} = ['**问题/目标**：' char(string(getStr(q, 'question', '')))];
    obj = strtrim(char(getStr(q, 'objective', '')));
    if ~isempty(obj)
        lines{end + 1} = '';
        lines{end + 1} = ['**建模目标**：' char(string(obj))];
    end
    sc = asCellstr(getField(q, 'success_criteria', {}));
    if ~isempty(sc)
        lines{end + 1} = '';
        lines{end + 1} = '**成功判据**：';
        for k = 1:numel(sc)
            lines{end + 1} = ['- ' sc{k}];
        end
    end
else
    lines{end + 1} = '（未记录）';
end
lines{end + 1} = '';
lines{end + 1} = '## 参考文献覆盖';
lines{end + 1} = '';
lines{end + 1} = sprintf('- 总数 %d；已核验 %d；有限访问 %d；未处理 %d（%.0f%% 完成）', ...
    cov.total, cov.read, cov.limited, cov.pending, cov.percent);
lines{end + 1} = sprintf('- 深度分布：full_text=%d, abstract_only=%d, citation_only=%d, 未标注=%d', ...
    cov.depths.full_text, cov.depths.abstract_only, ...
    cov.depths.citation_only, cov.depths.none);
if cov.read < cov.total
    lines{end + 1} = ['- 未完成核验：' strjoin(cov.blocking_ids, ', ')];
end
lines{end + 1} = '';
lines{end + 1} = '## 自检轮次';
lines{end + 1} = '';
rounds = bma.blind.internal.asStructList(p.selfcheck.rounds);
for k = 1:numel(rounds)
    r = rounds{k};
    lines{end + 1} = sprintf('%d. 第 %d 轮（%s）：%s', k, ...
        double(getNum(r, 'round', k)), char(getStr(r, 'at', '')), ...
        mdOneLine(char(getStr(r, 'summary', ''))));
    checks = bma.blind.internal.asStructList(getField(r, 'checks', {}));
    if ~isempty(checks)
        parts = {};
        for c = 1:numel(checks)
            parts{end + 1} = sprintf('%s=%s', ...
                char(getStr(checks{c}, 'name', '?')), ...
                char(getStr(checks{c}, 'result', '?'))); %#ok<AGROW>
        end
        lines{end + 1} = ['   - 检查：' strjoin(parts, '；')];
    end
end
if isempty(rounds)
    lines{end + 1} = '（未记录）';
end
lines{end + 1} = '';
lines{end + 1} = '## 问题台账与关闭理由';
lines{end + 1} = '';
if isempty(issues)
    lines{end + 1} = '（自检未发现问题）';
else
    lines{end + 1} = '| id | 严重度 | 类别 | 状态 | 标题 | 关闭理由/修复 |';
    lines{end + 1} = '|---|---|---|---|---|---|';
    for k = 1:numel(issues)
        it = issues{k};
        status = char(getStr(it, 'status', 'open'));
        why = '';
        if strcmp(status, 'fixed')
            why = [char(getStr(it, 'fix', '')) '（' char(getStr(it, 'fix_kind', '')) '）'];
        elseif strcmp(status, 'impossible')
            why = ['一般不可解：' char(getStr(it, 'reason', ''))];
        elseif strcmp(status, 'over_budget')
            why = ['超预算：' char(getStr(it, 'reason', ''))];
        end
        lines{end + 1} = sprintf('| %s | %s | %s | %s | %s | %s |', ...
            tableCell(getStr(it, 'id', '')), tableCell(getStr(it, 'severity', '')), ...
            tableCell(getStr(it, 'category', '')), tableCell(status), ...
            tableCell(getStr(it, 'title', '')), tableCell(why));
    end
end
lines{end + 1} = '';
lines{end + 1} = '## 停止判定';
lines{end + 1} = '';
stop = p.selfcheck.stop;
lines{end + 1} = sprintf('- 判定：%s（%s）', char(getStr(stop, 'verdict', '')), ...
    char(getStr(stop, 'evaluated_at', '')));
lines{end + 1} = sprintf('- 自检轮次：%d（要求 ≥%d）', st.rounds, st.min_rounds);
lines{end + 1} = sprintf('- 模型冻结版本：v%d', st.model.current);
lines{end + 1} = '';
lines{end + 1} = '> 说明：盲建模期间主文献全文未参与建模；解封后的模型对照见 `blind/model_comparison.md`（若已生成）。';
file = char(file);
bma.util.writeTextAtomic(file, strjoin(lines, char(10)));
end

% ---------------------------------------------------------------------------
function s = mdOneLine(s)
s = regexprep(char(s), '\s+', ' ');
end

function s = tableCell(v)
s = regexprep(char(string(v)), '\s+', ' ');
s = strrep(s, '|', '\|');
if numel(s) > 260
    s = [s(1:257) '...'];
end
end

function c = asCellstr(v)
if isempty(v)
    c = {};
elseif iscell(v)
    c = cellfun(@char, v(:)', 'UniformOutput', false);
elseif ischar(v)
    c = {char(v)};
else
    c = {char(string(v))};
end
end

function v = getStr(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = char(string(s.(f)));
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

function v = getField(s, f, d)
if isstruct(s) && isfield(s, f)
    v = s.(f);
else
    v = d;
end
end
