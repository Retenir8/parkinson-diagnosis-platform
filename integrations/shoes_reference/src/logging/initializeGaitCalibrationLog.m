function initializeGaitCalibrationLog(fileName)
% initializeGaitCalibrationLog  Create the per-session calibration CSV.

fid = fopen(fileName, 'w');
if fid < 0
    error('Cannot create calibration CSV file: %s', fileName);
end
cleanupObj = onCleanup(@() fclose(fid)); %#ok<NASGU>

header = ['sensor_t,event,foot,imu_samples,pressure_samples,duration_s,' ...
    'body_acc_bias_x,body_acc_bias_y,body_acc_bias_z,' ...
    'body_acc_noise_x,body_acc_noise_y,body_acc_noise_z,' ...
    'nav_acc_bias_x,nav_acc_bias_y,nav_acc_bias_z,' ...
    'standing_total,standing_cop_x,standing_cop_y,' ...
    'q0_w,q0_x,q0_y,q0_z,angular_rate_p95_deg_s,' ...
    'load_variation,pressure_zero_mean,pressure_zero_max,note'];
for k = 1:48
    header = sprintf('%s,pressure_zero_%02d', header, k);
end
for k = 1:48
    header = sprintf('%s,pressure_noise_%02d', header, k);
end
fprintf(fid, '%s\n', header);

end
