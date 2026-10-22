# Stegano carrier — plan v2 (pixel-domain, no implementation)

Transport disguise for beaut envelopes: every package is a **valid RGBA PNG**,
64×64 px, with the payload spread over **all channel bytes** (R, G, B, A).
Encryption is a standard AEAD; the image is deterministic — **no RNG, no seed,
no noise**. Packages are numbered and the transfer ends with an explicit
`EOP`; a receiver can ask for gaps by `stamp` and the sender regenerates the
exact same bytes.

```
beaut envelope → AEAD → package N/M → RGBA channels → PNG (.png)
```

Non-goals: PNG is framing + camouflage. Confidentiality and authenticity are
the AEAD's job; PNG CRC is not authentication.

---

## 0. Shell contract (exact variable names)

These are the names the editing script uses; everything else is derived from them.

```sh
STEGANO_MAX_SIZE=512M          # parsed to 536870912 bytes (per transfer)
SUFFIX=png                     # last extension is always .png
COLOR_SIZE=1                   # bytes per channel (PNG bit depth 8)
PIXEL_SIZE=4                   # RGBA: 4 * COLOR_SIZE
DATA_SIZE=$COLOR_SIZE          # payload bytes carried per channel
PNG_OFFSET=64                  # channel-bytes before the payload
W=64; H=64                     # canvas in pixels
STAMP=9f2c1a7b                 # transfer id (8 hex, sha256(source)[0:8])
COUNTER=000042                 # package seq, 6 digits, under flock

STEGANO_NAME="$(date '+%F%T' | sed 's/:/-/g')-${ADDR}-package.${STAMP}.${COUNTER}.${SUFFIX}"
# 2026-10-22-21-45-00-198.192.8.240-package.9f2c1a7b.000042.png
```

`date '+%F%T' | sed 's/:/-/g'` is the requested expression; the script may use
`date '+%F-%H-%M-%S'` internally because it produces the same string without a
pipe. `ADDR` is sanitized before use: `tr -c 'A-Za-z0-9._-' '_'`.

Derived, never configured independently:

```
CHANNELS  = PIXEL_SIZE / COLOR_SIZE        # 4 (R,G,B,A)
PIXELS    = W * H                          # 4,096
CAPACITY  = PIXELS * PIXEL_SIZE - PNG_OFFSET
```

---

## 1. Pixel format and parameters

```
COLOR_TYPE   = 6         # RGBA, 8-bit
COLOR_SIZE   = 1         # byte per channel
PIXEL_SIZE   = 4         # COLOR_SIZE * 4 (R,G,B,A)
PIXELS       = W * H     # 64 * 64 = 4096
PNG_OFFSET   = 64        # channel-bytes reserved before the payload
DATA_SIZE    = COLOR_SIZE  # payload bytes per channel (1 = full byte)
CAPACITY     = PIXELS * PIXEL_SIZE - PNG_OFFSET
             = 16384 - 64 = 16320 bytes  (~15.9 KiB per package)
```

Layout of the decoded pixel byte stream (row-major, top-left first):

```
[ 0        .. HEADER_SIZE )   package header (hidden in pixels)
[ HEADER_SIZE .. PNG_OFFSET ) deterministic filler
[ PNG_OFFSET .. +len )        ciphertext (this package)
[ ...      .. CAPACITY )      deterministic filler
```

Rules:

- `PIXEL_SIZE` and `COLOR_SIZE` are derived from the PNG header, never guessed.
- `PNG_OFFSET >= HEADER_SIZE`, must be `< CAPACITY`; invalid → refuse.
- `DATA_SIZE = COLOR_SIZE` means full-byte replacement — maximum capacity.
  A future `DATA_BITS < 8` variant can use only the low bits of each channel
  and keep a cover image, at `CAPACITY = PIXELS*PIXEL_SIZE*DATA_BITS/8` bits.
- Use **filter type 0 (None) on every scanline**. Decoders still accept any
  filter; the writer forces 0 so the byte-offset contract is stable.
- No interlace, no palette, bit depth 8, zlib level 0–1 (ciphertext does not
  compress; speed matters more).

64×64 RGBA = 16 KiB raw; the resulting PNG is ≈16.4 KiB. 512 MiB needs
≈32,897 packages — fine as a count, but see §7 for the per-transfer budget.

---

## 2. Deterministic filler (“randomness is never random”)

Unused channel bytes are produced by a **keyed PRF**, not an RNG:

```
KEYS = BLAKE2b-256(cluster_key, "beaut-stegano-keys")
filler[i] = BLAKE2b-256(KEYS, "filler" || stamp || package_seq || i)[0]
```

- No `randombytes_buf`, no seed, no external noise.
- Same cluster key + stamp + seq → **byte-identical PNG**, which is what makes
  `resend(stamp)` free: no storage of generated carriers, just regenerate.
- Different transfers get different filler because `stamp` is part of the input.
- The filler is not secret beyond the cluster key, but it leaks nothing: it is
  indistinguishable from the ciphertext to anyone without the key.

---

## 3. Package header (inside the pixels, at byte 0)

Big-endian, fixed size, `HEADER_SIZE = 64`:

```
magic       4   "BSTG"
version     1
flags       1   bit0 encrypted | bit1 EOP | bit2 signed | bit3 control
stamp       8   transfer id (also in the filename)
seq         4   1-based package index
total       4   package count, 0 while unknown
len         4   ciphertext length in this package
sha256     32   sha256 of the plaintext part
reserved    6
```

- The header sits at pixel-byte 0 and is covered by the AEAD as **AAD**, so a
  reader cannot be tricked by a modified `seq/total/EOP`.
- `len` is bounded by `CAPACITY - PNG_OFFSET` before any allocation.
- `total = 0` means streaming; `EOP` on the last package terminates the payload.

### Standard crypto

Use the primitive already in the project: **XChaCha20-Poly1305** (libsodium).
`BEAUT_PASSWORD` derives the cluster key with Argon2id as today; the envelope is
`nonce(24) || ciphertext`, AEAD associated data = the 64-byte header.
Optional Ed25519 signature over header+ciphertext when `flags.bit2`.

No custom crypto, no ROT13 in the data path. If a text-looking outer layer is
wanted later, it is a *transport codec* (`base64`, PNG), applied after the AEAD.

---

## 4. Sequencing, EOP, and gap recovery

A transfer is identified by `stamp` (8 bytes, e.g. `sha256(source)[0:8]` hex).
Packages are `seq = 1..total`, last one carries `EOP`.

```
receiver.state[stamp] = { total, recv:set(seq), eop:bool }
ask_missing_pkg(stamp) -> sorted(gaps)          # seqs not received, total known
resend(stamp, seqs...)  -> regenerate PNGs      # deterministic, byte-identical
```

- Receiver keeps a bitmap of received `seq`; `EOP` sets `total`.
- `ask_missing_pkg` returns gaps in `1..total`, or everything above the
  high-water mark while `total == 0`.
- `resend` needs only the original source blob + `stamp` (no carrier storage).
- Reassembly is accepted only when `EOP` is seen, all `1..total` present, and
  the concatenated AEAD plaintext matches the whole-package sha256.
- ACK/NAK defaults to a **control package**: 64×64 carrier, `flags.bit3` set,
  payload = received-seq bitmap. The sender then calls `resend(stamp, gaps)`.

---

## 5. Naming

`STEGANO_NAME` is defined once in §0; nothing else builds filenames by hand.

```sh
STEGANO_NAME="$(date '+%F%T' | sed 's/:/-/g')-${ADDR}-package.${STAMP}.${COUNTER}.${SUFFIX}"
# 2026-10-22-21-45-00-198.192.8.240-package.9f2c1a7b.000042.png
```

- `ADDR` sanitized with `tr -c 'A-Za-z0-9._-' '_'` (IPv6 colons would create paths).
- `COUNTER` is per-transfer `seq`, zero-padded 6, written under `flock`.
- Last extension is always `.png`; `COUNTER`/`STAMP` are also inside the header,
  so a renamed file is still decodable.
- `total` is known at send time (source size is known); `total=0`/`EOP` stays
  supported for unknown-length streams.

---

## 6. Script / tool split (plan)

Binary format stays in C; shell does policy. New verb on the existing tool:

```
$TOOL stegano embed  --in PART --out PNG --stamp S --seq N --total M [--eop] [--offset 64]
$TOOL stegano extract PNG --out PART        # verifies header + AEAD
$TOOL stegano verify  PNG
$TOOL stegano capacity [--size 64x64]
```

`scripts/stegano.sh`:

| cmd | does |
|---|---|
| `split -i BLOB [--addr A] [-w 64x64]` | chunk into `CAPACITY` parts, produce all PNGs |
| `embed -i PART -o PNG --stamp S --seq N --total M` | one package |
| `extract PNG -o PART` | one package |
| `verify PNG...` | dimensions, RGBA, filter walk, header, CRC, AEAD |
| `recv DIR` | reassemble by `stamp`, report missing |
| `ask_missing_pkg STAMP` | print gaps |
| `resend STAMP [SEQ...]` | regenerate from `$STATE/stegano/$STAMP/src` |
| `list` / `clean` | inventory, prune ACKed transfers |

Writer steps (pseudocode):

```
validate: W,H,COLOR_TYPE=6, OFFSET>=64, OFFSET<CAPACITY
raw = bytearray(W*H*4)
raw[0:64]            = header(stamp, seq, total, len, sha, EOP)
raw[64:OFFSET]       = prf_filler(stamp, seq)
raw[OFFSET:OFFSET+len] = aead(plain)
raw[OFFSET+len:]     = prf_filler(stamp, seq)
png = write_png(W, H, RGBA, filter0, zlib(raw))
atomic_write(out, png)         # tmp + fsync + rename, O_EXCL
```

Reader steps:

```
assert png signature; parse IHDR; require 8-bit RGBA, no interlace
inflate IDAT; unfilter rows; raw = row-major channel bytes
hdr = raw[0:64]; assert magic, version, len<=CAPACITY-OFFSET
assert seq<=total (when total>0); AEAD-open(AAD=hdr); sha256(plain)==hdr.sha
```

Hard rules: never trust `len/total/W/H` before bounds checks; never allocate
more than `STEGANO_MAX_SIZE`; temps `0600`, carriers `0644`; no plaintext ever
appears in `tEXt` or filenames.

---

## 7. Budget

| item | value |
|---|---|
| raw RGBA per package | 16,384 B |
| payload per package | 16,320 B |
| PNG on disk | ≈16.4 KiB |
| 512 MiB transfer | 32,897 packages |
| 1 GiB transfer | 65,794 packages |

`STEGANO_MAX_SIZE` therefore means **per transfer** (the sum of all packages),
not per file. A single package is hard-capped at `CAPACITY`.
If the package count is too high for the link, enlarge the canvas:
`W=H=128` → 65,472 B payload/package, 4× fewer files; the pixel contract and
header are unchanged. 64 px stays the default.

---

## 8. Tests

1. `file x.png` → PNG; `pngcheck -v` clean; Pillow opens it.
2. Round-trip for part sizes 0, 1, 64 B, `CAPACITY−1`, `CAPACITY`.
3. `CAPACITY+1` rejected before allocation.
4. Two runs with same key/stamp/seq → **identical sha256** (determinism).
5. Different stamp → different filler/PNG.
6. Flip one channel byte → AEAD fails; flip header `seq` → AEAD fails (AAD).
7. `total=0` stream + EOP → recv completes; missing middle → `ask_missing_pkg` returns exactly that seq; `resend` reproduces byte-identical PNG.
8. 100 parallel `embed` calls → contiguous distinct counters.
9. `strings x.png` contains no plaintext or original filename.
10. Alpha=0 pixels are still readable (data is in the file, not the composite).

---

## 9. Decisions (closed)

- **All four channels carry data**, alpha included; the rendered composite is
  irrelevant, only the file bytes matter. No “keep alpha opaque” mode.
- **`STEGANO_MAX_SIZE=512M` is the per-transfer cap.** A single package is
  hard-capped at `CAPACITY` (16,320 B at 64×64).
- **Default canvas is 64×64.** Larger canvases (128×128 → 65,472 B/package) are
  a capacity knob, not a different format.
- **`total` is known at send time** (the source size is known); `total=0` and
  streaming until `EOP` remain supported for unknown-length sources.
- **ACK/NAK is a control package**: same 64×64 carrier, same header, `flags.bit3`
  set, payload = bitmap of received `seq`. It is small enough that no separate
  channel is required; out-of-band is allowed but not the default.
- **`DATA_BITS < 8` is not part of v2.** It stays as a future variant for a
  human-looking cover; v2 is deterministic full-byte embedding.

