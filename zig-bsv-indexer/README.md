# bsv-indexer

Ultra-low-latency SPV indexer for Bitcoin SV. Written in Zig.

## Goals

- **Sub-microsecond UTXO/tx queries** via hugepages-backed hot cache + cache-line aligned data structures
- **Full UTXO set** (~100M UTXOs, 50GB+) with tiered storage: hot (hugepages) → warm (mmap LSM) → cold (block files)
- **Library-first API** (C-ABI) for zero-overhead FFI from Zig, C, Rust, Go, Python
- **P2P headers-first sync** from genesis — no trusted third party
- **Generic BSV script VM** — execute any opcode, pattern-match templates post-hoc

## Architecture

```
libbsvindex (Zig, C-ABI)
├── Hot Cache      — hugepages (2MB/1GB), LRU, ~1-5M active UTXOs
├── Warm Cache     — mmap'd sorted segments (LSM-tree), rest of UTXO set
├── P2P Sync       — parallel header download, streaming block parse, SPV proofs
├── Script VM      — comptime opcode tables, zero-copy parsing, stack/altstack
└── Crypto         — secp256k1 (verify/recover), SHA256d, RIPEMD160, Hash160
```

## Build

```bash
# Requires Zig 0.13+, Linux with hugepages configured
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Benchmarks
zig build bench
```

## Hugepages Setup (Linux)

```bash
# Reserve 4GB hugepages (adjust as needed)
echo 2048 | sudo tee /proc/sys/vm/nr_hugepages
sudo mkdir -p /mnt/hugepages
sudo mount -t hugetlbfs nodev /mnt/hugepages
sudo chown $USER:$USER /mnt/hugepages
```

## API (C-ABI)

```c
// Opaque handle
typedef struct bsv_indexer_t bsv_indexer_t;

bsv_indexer_t* bsv_indexer_open(const char* data_dir, size_t hot_mib, size_t warm_mib);
void bsv_indexer_close(bsv_indexer_t* idx);

// Query
bool bsv_indexer_get_utxo(bsv_indexer_t* idx, const uint8_t txid[32], uint32_t vout, bsv_utxo_t* out);
void bsv_indexer_scan_script(bsv_indexer_t* idx, const uint8_t* pattern, size_t len, bsv_scan_cb cb, void* ctx);

// Sync
int bsv_indexer_sync(bsv_indexer_t* idx);

// Chain state
uint32_t bsv_indexer_height(bsv_indexer_t* idx);
void bsv_indexer_tip_hash(bsv_indexer_t* idx, uint8_t hash[32]);
```

## Status

**Pre-alpha** — core skeleton only. Missing:
- [ ] Warm cache LSM implementation
- [ ] P2P wire protocol + header sync
- [ ] Script VM opcode implementations
- [ ] C-ABI headers + FFI exports
- [ ] Benchmarks / CI

## License

MIT