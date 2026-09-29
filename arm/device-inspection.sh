#!/bin/sh
uname -a
cat /proc/cpuinfo
cat /proc/version
ls -l /lib/ld* /lib/libc* /lib/libpthread* 2>/dev/null
cat /proc/meminfo
