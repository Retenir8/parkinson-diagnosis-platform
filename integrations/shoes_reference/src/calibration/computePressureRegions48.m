function region = computePressureRegions48(P, cfg)

P = double(P(:)');

if numel(P) ~= 48
    error('computePressureRegions48:InvalidInput', ...
        'Pressure vector must contain 48 values.');
end

S = zeros(12, 4);

S(:,1) = P(1:12);
S(:,2) = P(13:24);
S(:,3) = P(25:36);
S(:,4) = P(37:48);

region = struct();
region.S = S;

region.total = sum(S(:));

region.heel = sum(sum(S(cfg.heelRows, :)));
region.mid = sum(sum(S(cfg.midRows, :)));
region.fore = sum(sum(S(cfg.foreRows, :)));
region.toe = sum(sum(S(cfg.toeRows, :)));

region.medial = sum(sum(S(:, cfg.medialCols)));
region.lateral = sum(sum(S(:, cfg.lateralCols)));

[X, Y] = meshgrid(1:4, 1:12);
den = max(region.total, 1e-6);

copX = sum(sum(S .* X)) / den;
copY = sum(sum(S .* Y)) / den;

region.copX = copX;
region.copY = copY;

region.copXNorm = (copX - 1) / 3;
region.copYNorm = (copY - 1) / 11;

end
