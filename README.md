# Odysseus Kernel — BSV Native Unikernel

**Kernel especializado para Bitcoin SV.** Indexación UTXO en slots fijos con optimizaciones assembly, agente autónomo integrado, y capacidades cripto a nivel kernel. Diseñado para correr desde CPUs x86_64 hasta microcontroladores ESP32.

## Filosofía

Cada wallet tiene su propio backend. Nosotros unificamos todo a nivel kernel.

- UTXOs almacenadas en un **stack de slots fijos** (64B c/u, cache-line aligned)
- Cada UTXO ocupa una posición exacta en memoria → O(1) lookup por slot index
- Operaciones cripto (SHA256d, RIPEMD160, secp256k1) ejecutadas en local, sin dependencias externas
- Agente de comercio autónomo integrado como runtime del kernel
- Unikernel: un solo binario que corre directo sobre hardware o como proceso bare-metal

## Arquitectura

```
┌──────────────────────────────────────────────────┐
│  Capa 4 — OS / Aplicaciones                     │
│  (BRC100 wallets, trading agent, creative tools) │
├──────────────────────────────────────────────────┤
│  Capa 3 — Agent Runtime (kernel-space)           │
│  (scheduler, tools, MCP-like IPC)                │
├──────────────────────────────────────────────────┤
│  Capa 2 — BSV Engine                             │
│  (script VM, P2P SPV, opcode builder)            │
├──────────────────────────────────────────────────┤
│  Capa 1 — UTXO Stack Engine                      │
│  (slots fijos 64B, bitmap occupancy, asm ops)    │
├──────────────────────────────────────────────────┤
│  Capa 0 — Kernel HAL                             │
│  (x86_64, ARM, RISC-V, ESP32)                    │
│  (boot, memoria, interrupciones, cache asm)      │
└──────────────────────────────────────────────────┘
```

## Layout del Slot UTXO (64 bytes exactos)

```
Offset  Campo         Tamaño  Descripción
0       txid          32      SHA256 txid
32      vout           4      Output index
36      value          8      Satoshis (uint64)
44      height         4      Block height
48      flags          2      spent, locked, coinbase
50      script_off     4      Offset en heap de scripts
54      script_len     4      Longitud del script
58      padding        6      → 64B exactos (cache line)
```

## Targets Soportados

| Target       | Estado     | Slots estimados | RAM requerida |
|-------------|------------|-----------------|---------------|
| x86_64      | ✅ En desarrollo | 100M           | ~6.4 GB       |
| aarch64     | 🔧 Próximo | 50M             | ~3.2 GB       |
| riscv64     | 🔧 Próximo | 10M             | ~640 MB       |
| ARM (v7)    | 🔧 Próximo | 1M              | ~64 MB        |
| ESP32       | 📋 Planeado | 8,192           | ~512 KB       |

## Compilar

```bash
# Requiere Zig 0.14.0+
zig build -Doptimize=ReleaseFast

# Compilar para target específico
zig build -Dtarget=x86_64-freestanding
zig build -Dtarget=aarch64-freestanding
zig build -Dtarget=riscv64-freestanding

# Tests
zig build test
zig build test-x86_64
zig build test-aarch64

# Benchmarks
zig build bench
./zig-out/bin/utxo-bench
```

## Benchmarks (esperados)

| Operación          | Throughput     |
|-------------------|----------------|
| Insert slot       | ~50M ops/sec   |
| Find by outpoint  | ~30M ops/sec   |
| Scan script       | ~20M ops/sec   |
| SHA256d           | ~1M hashes/sec |

## Stack Tecnológico

- **Lenguaje:** Zig 0.14.0 (cross-compilation nativa)
- **Assembly:** Inline asm para x86_64 (`clflushopt`, `prefetcht0`, `rep movsb`, `bsf`) y ARM (`dc cvau`, `prfm`, `clz`)
- **Cripto:** SHA256, RIPEMD160, secp256k1 — todo en local, sin OpenSSL
- **Memoria:** Hugepages (2MB/1GB) para slot array, bump allocator para scripts
- **Agente:** Scheduler cooperativo con tool system, MCP-like IPC + [Ulises](ulises/) AI workspace integrado
- **SMP:** Soporte multiprocesador simétrico vía ACPI MADT + Local APIC + IPI
- **Sincronización:** Ticket spinlocks (fair), IRQ-safe locks, operaciones atómicas
- **USB:** Driver teclado USB HID vía UHCI (reemplaza al antiguo PS/2)
- **PCI:** Enumerador de dispositivos PCI
- **NIC:** Driver Intel e1000
- **Shell:** Shell interactiva nativa con 16 comandos, historial, temas

## Inspiración y Referencias

- [Ulises](ulises/) — AI workspace integrado como agente del kernel (fork de Odysseus rebrandeado)
- [Odysseus original](https://github.com/pewdiepie-archdaemon/odysseus) — AI workspace de PewDiePie
- [bsvz](https://github.com/b-open-io/bsvz) — BSV foundation library para Zig
- SteamOS GUI reference: [docs/gui-reference-steamos.md](docs/gui-reference-steamos.md)

## Licencia

MIT
