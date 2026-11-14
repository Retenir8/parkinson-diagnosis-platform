function qAvg = averageQuaternionWxyz(qList)

Q = double(qList);

if isempty(Q)
    qAvg = [1 0 0 0];
    return;
end

qRef = Q(1,:);

for i = 1:size(Q,1)
    Q(i,:) = Q(i,:) ./ max(norm(Q(i,:)), 1e-12);

    if dot(Q(i,:), qRef) < 0
        Q(i,:) = -Q(i,:);
    end
end

qAvg = mean(Q, 1);
qAvg = qAvg ./ max(norm(qAvg), 1e-12);

end
