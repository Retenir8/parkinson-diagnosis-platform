function vRot = quatRotateVectorWxyz(q, v)

q = double(q(:)');
v = double(v(:)');

q = q ./ max(norm(q), 1e-12);

qv = [0 v];
qc = quatConjWxyz(q);

tmp = quatMultiplyWxyz(q, qv);
out = quatMultiplyWxyz(tmp, qc);

vRot = out(2:4);

end
