# metricscheck.sh FILE: Prometheus text exposition 0.0.4 as u2ac-metrics writes it
awk '
/^# HELP [a-z_][a-z0-9_]* ./ { next }
/^# TYPE [a-z_][a-z0-9_]* (gauge|counter)$/ { if ($3 in typed) { dup++; print "DUP " $3 } typed[$3] = 1; cur = $3; next }
/^[a-z_][a-z0-9_]*(\{[a-z_][a-z0-9_]*="[^"\\]*"(,[a-z_][a-z0-9_]*="[^"\\]*")*\})? -?[0-9][0-9.e+-]*$/ {
    n = $1; sub(/\{.*/, "", n); if (n != cur) { split_++; print "OUTSIDE " $0 } ok++; next }
{ bad++; print "BAD " $0 }
END { printf "--- metrics: %d samples, %d bad, %d dup, %d outside\n", ok, bad + 0, dup + 0, split_ + 0 }' "$1"
echo "--- metrics macs: $(grep -ciE '[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]' "$1")"
