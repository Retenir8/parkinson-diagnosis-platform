function rb = initMessageRingBuffer(capacity)

if nargin < 1 || isempty(capacity)
    capacity = 5000;
end

rb = struct();
rb.capacity = capacity;
rb.data = cell(capacity, 1);
rb.head = 1;
rb.tail = 1;
rb.count = 0;
rb.dropCount = 0;

end
