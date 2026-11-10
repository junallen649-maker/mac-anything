#!/bin/bash
export PATH=/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH
export MSYSTEM=UCRT64
export MSYS2_ARG_CONV_EXCL=*
cd /d/reims/reims-vgpu-windows-native-tahoe/build/qemu || exit 1
echo "=== START $(date) ==="
ninja -j4 qemu-system-x86_64.exe qemu-img.exe qemu-io.exe
code=$?
echo "=== NINJA_EXIT=$code $(date) ==="
exit $code