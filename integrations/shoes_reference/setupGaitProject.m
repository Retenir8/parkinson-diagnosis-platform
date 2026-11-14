function projectRoot = setupGaitProject()
% setupGaitProject  Add the maintained project source tree to the MATLAB path.

projectRoot = fileparts(mfilename('fullpath'));
sourceRoot = fullfile(projectRoot, 'src');
if exist(sourceRoot, 'dir') ~= 7
    error('gait:MissingSourceDirectory', ...
        'Project source directory not found: %s', sourceRoot);
end

addpath(genpath(sourceRoot));

end
