% test_report_images.m — 0.8.5 report figure dedup + responsive width
%
% Regression: images referenced by extra sections were copied into
% report/figures, then collected again by the generic figures glob; the same
% image also appeared via artifacts/**. Also raw extra-section <img> had no
% max-width, so wide figures overflowed the 1080px page.
root = bma.util.projectRoot();
runDir = fullfile(root, '.bma', 'test_tmp', bma.util.newId('report_images'));
bma.util.ensureDir(fullfile(runDir, 'figures'));
bma.util.ensureDir(fullfile(runDir, 'artifacts'));

% Shared: referenced by extra section; duplicate copy in artifacts must be
% suppressed by content hash.
shared = fullfile(runDir, 'figures', 'shared.png');
imwrite(repmat(uint8(200), 40, 80, 3), shared);
copyfile(shared, fullfile(runDir, 'artifacts', 'shared_dup.png'));
% Model figure not referenced by extra section: must appear once in §11.
modelFig = fullfile(runDir, 'figures', 'model.png');
imwrite(repmat(uint8(100), 40, 80, 3), modelFig);
% Artifact not referenced by extra section: must appear once in §11.
artifactFig = fullfile(runDir, 'artifacts', 'artifact.png');
imwrite(repmat(uint8(50), 40, 80, 3), artifactFig);

specPath = fullfile(root, 'spec', 'examples', 'enzyme_mm.json');
opts = struct();
opts.title = 'report image regression';
opts.extra_sections = {struct('title', '图复现', ...
    'markdown', '![shared](figures/shared.png)')};
rep = bma.report.build(runDir, specPath, [], [], opts);
htmlPath = bma.util.absPath(root, rep.report_html);
mdPath = bma.util.absPath(root, rep.report_md);
html = fileread(htmlPath);
md = fileread(mdPath);

imgs = regexp(html, '<img[^>]*>', 'match');
assert(numel(imgs) == 3, '图片数量应为 3（shared + model + artifact），实际 %d', numel(imgs));
srcs = regexp(html, 'src="data:([^;]+);base64,([^"]+)"', 'tokens');
assert(numel(srcs) == 3, 'data URI 数量应为 3，实际 %d', numel(srcs));
assert(numel(unique(cellfun(@(c) c{2}, srcs, 'UniformOutput', false))) == 3, ...
    '报告仍有重复图片（data URI 不唯一）');
assert(~isempty(strfind(html, 'img{max-width:100%;height:auto;}')), ...
    '缺少全局图片 max-width');
assert(~isempty(strfind(html, 'table.md{border-collapse:collapse;width:100%;table-layout:fixed;')), ...
    '缺少 Markdown 表格 fixed layout，窄表格图片可能溢出');
assert(numel(regexp(md, '!\[[^\]]*\]\([^)]+\)', 'match')) == 3, ...
    'Markdown 图片数量应为 3');
fprintf('[PASS] report images: 3 unique, global max-width, fixed md table\n');
