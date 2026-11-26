#!/bin/sh
# run inside the arm rootfs: every ELF must load (missing libs -> loader error)
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
for f in $(find / -xdev -type f \( -path '/usr/*' -o -path '/bin/*' -o -path '/sbin/*' -o -path '/lib/*' \) 2>/dev/null); do
  case "$f" in *.ko|*.so*|*/firmware/*|*.hcd|*.txt|*.bin|*.conf|*.html|*.md|*.toml) continue;; esac
  head -c4 "$f" 2>/dev/null | grep -q 'ELF' || continue
  out=$(timeout 5 "$f" --help </dev/null 2>&1 | head -3)
  case "$out" in *"error while loading"*|*"not found"*|*"No such file"*|*"cannot open shared"*) echo "BROKEN $f: $out";; *) echo "ok $f";; esac
done
