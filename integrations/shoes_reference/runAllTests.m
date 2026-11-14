function results = runAllTests()
% runAllTests  Run the maintained automated regression suite.

projectRoot = setupGaitProject();
results = runtests(fullfile(projectRoot, 'tests'));

if nargout == 0
    disp(results);
    assertSuccess(results);
    clear results;
end

end
