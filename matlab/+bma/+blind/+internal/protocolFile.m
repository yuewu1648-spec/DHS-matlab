function p = protocolFile(runDir)
%PROTOCOLFILE Path of the blind-literature protocol for one run.
p = fullfile(char(runDir), 'blind', 'protocol.json');
end
