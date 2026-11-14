function [rb, batch] = popMessageBatchRingBuffer(rb, maxN)

if nargin < 2 || isempty(maxN)
    maxN = rb.count;
end

n = min(maxN, rb.count);
batch = cell(n,1);

for i = 1:n
    batch{i} = rb.data{rb.head};
    rb.data{rb.head} = [];
    rb.head = rb.head + 1;
    if rb.head > rb.capacity
        rb.head = 1;
    end
end

rb.count = rb.count - n;

end
