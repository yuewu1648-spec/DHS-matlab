% test_io_sentences.m — 句子级引用 + 数字 sentence_id（ISS-12）
root = bma.util.projectRoot();
runDir = fullfile(root, '.bma', 'test_tmp', 'sentence_ingest');
if isfolder(runDir), rmdir(runDir, 's'); end
md = fullfile(root, 'tests', 'fixtures', 'literature', 'enzyme_kinetics', 'paper.md');
doc = bma.io.ingest(md, runDir, struct('WorkDir', root));

assert(doc.sentence_count > 20, '句子数过少：%d', doc.sentence_count);
assert(isfile(fullfile(root, doc.sentences_path)), 'sentences.json 未写出');
sent = bma.util.readJson(fullfile(root, doc.sentences_path));
assert(numel(sent) == doc.sentence_count, 'sentences.json 数量不一致');

% 1) 每个 section 都有 sentences；id 唯一且为 sec#sN
seen = containers.Map('KeyType', 'char', 'ValueType', 'logical');
for s = 1:numel(doc.sections)
    assert(isfield(doc.sections(s), 'sentences'), '章节缺少 sentences 字段');
    items = doc.sections(s).sentences;
    for k = 1:numel(items)
        it = items(k);
        assert(~isempty(regexp(it.id, '^[^#]+#s\d+$', 'once')), '句子 id 格式错误：%s', it.id);
        assert(~isKey(seen, it.id), '句子 id 重复：%s', it.id);
        seen(it.id) = true;
        % 2) 偏移必须能取回句子文本（允许空白折叠）
        seg = doc.sections(s).text;
        % sections 的 text 经过 strtrim，但 sentences 偏移是全文坐标：
        % 这里用全文文件验证
    end
end
txt = fileread(fullfile(root, doc.text_path));
for k = 1:numel(sent)
    it = sent(k);
    assert(it.char_start >= 1 && it.char_end <= numel(txt) && it.char_end >= it.char_start, ...
        '句子偏移越界：%s', it.id);
    got = txt(it.char_start:it.char_end);
    got = regexprep(got, '\s+', ' ');
    want = regexprep(it.text, '\s+', ' ');
    assert(strcmp(strtrim(got), strtrim(want)), '句子文本与偏移不一致：%s', it.id);
end
fprintf('[PASS] sentences: %d ids, offsets round-trip, sections carry sentences\n', numel(sent));

% 3) 数字的 sentence_id 必须存在于句子表，且位置落在该句内
map = containers.Map('KeyType', 'char', 'ValueType', 'double');
for k = 1:numel(sent)
    map(sent(k).id) = k;
end
nWith = 0;
for k = 1:numel(doc.numbers)
    n = doc.numbers(k);
    assert(isfield(n, 'sentence_id'), '数字缺少 sentence_id 字段');
    if isempty(n.sentence_id)
        continue
    end
    assert(isKey(map, n.sentence_id), '数字引用了未知句子：%s', n.sentence_id);
    it = sent(map(n.sentence_id));
    assert(n.char_start >= it.char_start && n.char_start <= it.char_end, ...
        '数字位置不在其句子内：%s', n.sentence_id);
    nWith = nWith + 1;
end
assert(nWith > 0, '没有任何数字分配到 sentence_id');
fprintf('[PASS] numbers: %d/%d carry sentence_id\n', nWith, numel(doc.numbers));

% 4) 跨行下标符号：ks\n2 = 3.5e-4 1/s -> ks2
synth = ['The rate constant ks' char(10) '2 = 3.5e-4 1/s was estimated at pH 7.2.' ...
    char(10) char(10) 'It matches the literature.'];
secs = bma.io.sectionize(synth);
nums = bma.io.extractNumbers(synth, secs);
hit = false;
for k = 1:numel(nums)
    if strcmp(nums(k).symbol, 'ks2')
        hit = true;
    end
end
assert(hit, '跨行下标符号未合并为 ks2（符号：%s）', ...
    strjoin({nums.symbol}, ','));
fprintf('[PASS] cross-line subscript symbol ks2 recovered\n');
