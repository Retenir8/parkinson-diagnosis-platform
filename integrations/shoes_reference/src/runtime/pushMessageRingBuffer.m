function rb = pushMessageRingBuffer(rb, item)

if rb.count >= rb.capacity
    rb.head = rb.head + 1;
    if rb.head > rb.capacity
        rb.head = 1;
    end
    rb.count = rb.count - 1;
    rb.dropCount = rb.dropCount + 1;
end

rb.data{rb.tail} = item;
rb.tail = rb.tail + 1;
if rb.tail > rb.capacity
    rb.tail = 1;
end

rb.count = rb.count + 1;

end
