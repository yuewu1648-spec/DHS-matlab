function [sid, heading, idx] = sectionAt(sections, pos)
%SECTIONAT 查找某个字符位置所属的章节。
%   [sid, heading, idx] = bma.io.internal.sectionAt(sections, pos)
%   sections 为 bma.io.sectionize 返回的 struct 数组；pos 为 1-based 字符位置。
sid = '';
heading = '';
idx = 0;
if isempty(sections) || ~isstruct(sections) || ~isfield(sections, 'char_start')
    return
end
starts = [sections.char_start];
idx = find(starts <= pos, 1, 'last');
if isempty(idx)
    idx = 1;
end
sid = sections(idx).id;
heading = sections(idx).heading;
end
