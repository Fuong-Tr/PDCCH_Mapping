#!/usr/bin/env bash
# Chạy từ bất kỳ thư mục nào; không giữ file build trong repo.
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
if command -v iverilog >/dev/null && command -v vvp >/dev/null; then
    iverilog -g2012 -Wall -s tb_pdcch_packer -o "$build_dir/sim" pdcch_packer.v tb_pdcch_packer.v
    runner=(vvp "$build_dir/sim")
elif command -v verilator >/dev/null; then
    verilator --binary --timing -j 2 -CFLAGS '-std=c++20' \
        --top-module tb_pdcch_packer --Mdir "$build_dir/obj" \
        pdcch_packer.v tb_pdcch_packer.v > "$build_dir/build.log" 2>&1 || {
            cat "$build_dir/build.log"; exit 1;
        }
    runner=("$build_dir/obj/Vtb_pdcch_packer")
else
    echo 'Cần cài Icarus Verilog (iverilog/vvp) hoặc Verilator có hỗ trợ timing.' >&2
    exit 1
fi
for seed in default 1 2 3 7 19 42 123 999 12345 2147483647; do
    args=()
    if [[ "$seed" != default ]]; then args=("+SEED=$seed"); fi
    "${runner[@]}" "${args[@]}" > "$build_dir/run.log" 2>&1 || {
        cat "$build_dir/run.log"; exit 1;
    }
    echo "Seed=$seed"
    grep 'ALL PASS' "$build_dir/run.log"
done
