if (.ticks | length) < 50 then error("too few timing samples") else . end |
([range(1; (.ticks | length)) as $i | (.ticks[$i] - .ticks[$i-1]) * 1000] | max) as $max_interval |
if $max_interval >= 50 then error("timing loop stalled for 50 ms or more") else . end |
if .workerStillActive or .readbackA != 0 or .readbackB != 0 then error("worker or readback failed") else . end |
if (.finalA - 250 | fabs) > 2 or (.finalB - 550 | fabs) > 2 then error("fixture did not reach its final positions") else . end |
if (.events | length) == 0 or .events[-1].offset != 0 then error("latest request was not completed") else . end |
if any(.events[]; .firstStatus != 0 or .secondStatus != 0) then error("Accessibility request failed") else . end |
{max_interval_ms: $max_interval, submitted: (.ticks | length), completed: (.events | length), final: [.finalA, .finalB]}
