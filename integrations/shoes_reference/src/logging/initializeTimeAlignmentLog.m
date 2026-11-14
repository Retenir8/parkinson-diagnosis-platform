function initializeTimeAlignmentLog(fileName)
% initializeTimeAlignmentLog  Create the per-session clock alignment CSV.

fid = fopen(fileName, 'w');
if fid < 0
    error('Cannot create time alignment CSV file: %s', fileName);
end
cleanupObj = onCleanup(@() fclose(fid)); %#ok<NASGU>

fprintf(fid, [ ...
    'arrival_t,event,method,status,reference_foot,' ...
    'right_to_left_offset_sec,quality_spread_sec,' ...
    'left_samples,right_samples,pair_count,' ...
    'left_arrival_minus_gateway_sec,right_arrival_minus_gateway_sec,' ...
    'offset_samples_sec,left_peak_gateway_t,right_peak_gateway_t,note\n']);

end
