function s = nowIso()
%NOWISO Current local time as an ISO-8601 string with offset.
s = char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ssXXX', ...
    'TimeZone', 'local'));
end
