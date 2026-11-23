function writePrimaryAbstract(workDir, runDir, p)
%WRITEPRIMARYABSTRACT Write the sealed abstract dossier (abstract only).
%   The file is the only human/agent-readable view of the primary paper during
%   blind modeling: metadata plus the extracted abstract text.
file = fullfile(runDir, 'blind', 'primary_abstract.md');
ab = p.primary.abstract;
lines = {
    '# 主文献摘要（盲建模封印）'
    ''
    ['- 标题：' char(p.primary.title)]
    ['- 文件：' char(p.primary.source_rel)]
    ['- SHA-256：' char(p.primary.sha256)]
    ['- 字节数：' sprintf('%d', double(p.primary.bytes))]
    ['- 摘要来源：' char(ab.source)]
    ['- 摘要置信度：' char(ab.confidence)]
    ['- 摘要字数：' sprintf('%d', double(ab.chars))]
    ''
    '---'
    ''
    char(ab.text)
    ''
    '---'
    ''
    '> 建模期间只允许使用本摘要。主文献全文、图、表由盲建模协议封印；`bma_literature_ingest` 会拒绝该文件。'
    '> 参考文献请逐篇用 `bma_blind_note` 登记（quote 会被逐字校验）。'
    };
bma.util.writeTextAtomic(file, strjoin(lines, char(10)));
end
