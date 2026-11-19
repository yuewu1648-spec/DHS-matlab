% test_io_figures.m — PDF 位图插图抽取（ISS-12）
root = bma.util.projectRoot();
outDir = fullfile(root, '.bma', 'test_tmp', 'pdf_figures');
if isfolder(outDir), rmdir(outDir, 's'); end
pdf = fullfile(root, 'tests', 'fixtures', 'upgrade', 'pdf', 's00421-002-0676-3.pdf');
out = bma.io.extractPdfFigures(pdf, outDir, struct());
assert(out.ok && out.count >= 3, 'PDF 位图抽取不足 3 张（%d）', out.count);
for k = 1:out.count
    f = out.figures(k);
    fp = fullfile(outDir, f.file);
    assert(isfile(fp), '图不存在：%s', fp);
    info = imfinfo(fp);
    assert(info.Width == f.width && info.Height == f.height, '图尺寸不一致：%s', f.file);
    assert(info.Width > 200 && info.Height > 200, '图过小：%s', f.file);
end
assert(isfile(out.figures_json), 'figures.json 未写出');
manifest = bma.util.readJson(out.figures_json);
assert(manifest.count == out.count && numel(manifest.figures) == out.count, ...
    'figures.json 与返回不一致');
fprintf('[PASS] extractPdfFigures: %d bitmap(s), manifest OK\n', out.count);

% 矢量图 PDF：应返回明确告警而不是崩溃
pdfVec = fullfile(root, 'tests', 'fixtures', 'upgrade', 'pdf', 's00421-026-06316-4.pdf');
outVec = bma.io.extractPdfFigures(pdfVec, fullfile(outDir, 'vector'), struct());
assert(~outVec.ok && outVec.count == 0 && ~isempty(outVec.warnings), ...
    '矢量 PDF 应返回 0 图 + 告警');
assert(strcmp(outVec.figure_class, 'vector'), '矢量 PDF 应标记 figure_class=vector');
assert(outVec.vector_only && ~outVec.rasterized, '矢量 PDF 应标记 vector_only/rasterized=false');
fprintf('[PASS] vector-only PDF: 0 figure + figure_class=vector + explicit warning\n');

% ingest 集成：图数量/清单/相对路径
runDir = fullfile(root, '.bma', 'test_tmp', 'pdf_ingest');
if isfolder(runDir), rmdir(runDir, 's'); end
doc = bma.io.ingest(pdf, runDir, struct('WorkDir', root));
assert(doc.figure_count == out.count, 'ingest 图数量不一致：%d vs %d', ...
    doc.figure_count, out.count);
assert(strcmp(doc.figure_class, 'bitmap'), 'ingest 应传递 figure_class');
assert(doc.text_chars_total >= doc.text_chars, 'ingest 应记录 text_chars_total/text_chars');
assert(~isempty(doc.figures_path) && isfile(fullfile(root, doc.figures_path)), ...
    'ingest figures.json 不存在');
for k = 1:doc.figure_count
    assert(isfile(fullfile(root, doc.figures(k).rel_path)), 'ingest 图文件缺失');
end
fprintf('[PASS] literature.ingest: %d figures + figures.json + rel paths\n', doc.figure_count);
