function qc = quatConjWxyz(q)

q = double(q(:)');
qc = [q(1), -q(2), -q(3), -q(4)];

end
