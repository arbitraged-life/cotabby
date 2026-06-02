# Reverse Engineering Cotypist.app — Tools & Methods

This document captures the tools, techniques, and findings from reverse-engineering `/Applications/Cotypist.app` (v0.22.1+) to understand its architecture and achieve feature parity with CoTabby.

## Executive Summary

Cotypist is a closed-source macOS autocomplete app distributed via the App Store. We reverse-engineered its binary architecture to identify key differentiators:

- **DTSM (Decode Tree Sequence Manager)**: Multi-sequence inference with shared KV cache prefix
- **Tree decoding**: Generates N candidates simultaneously per iteration; ranked by probability
- **FIM-mode prompts**: `<|fim_begin|>prefix<|fim_hole|>suffix<|fim_end|>` for mid-line completions
- **Session-based personalization**: Accept/reject logs + optional LoRA adapters

All analysis was performed on the binary and class interfaces without accessing proprietary algorithms or encrypted data.

---

## Tools Installed & Used

### 1. **class-dump** — Extract Objective-C/Swift Class Signatures
**Purpose**: Decompose the Mach-O binary into readable class and method signatures.

```bash
# Installation
brew install class-dump

# Usage
class-dump /Applications/Cotypist.app/Contents/MacOS/Cotypist > cotypist-classdump.txt

# Output: ~10,000 lines of class definitions, method signatures, ivars
```

**What we found**:
- `GenerationManager` with `maxSearchWidth`, `maxResultWidth`, `DTSM` ivar references
- `DecodeTreeSequenceManager` managing multiple sequence IDs
- `FillInTheMiddleMode` enum for prompt templates
- Session-based `PersonalizationEngine` and `LoRAAdapterLoader`

**Limitations**:
- Only method signatures, not implementations
- Stripped of local variable names (generic `a`, `b`, `c` naming)
- No insight into algorithm logic, just interfaces

---

### 2. **strings** — Extract Embedded Text & Constants
**Purpose**: Dump all ASCII/UTF-8 strings embedded in the binary.

```bash
# Extract all strings
strings /Applications/Cotypist.app/Contents/MacOS/Cotypist | grep -i "tree\|dtsm\|fim" > strings-output.txt

# Search for specific patterns
strings /Applications/Cotypist.app/Contents/MacOS/Cotypist | grep -E "lora|adapter|personalize"
```

**What we found**:
- Prompt template fragments: `<|fim_begin|>`, `<|fim_hole|>`, `<|fim_end|>`
- Model names: references to `Gemma`, `CodeGemma`, `Llama` variants
- Error messages: `"tree depth exceeded"`, `"KV cache overflow"`
- Configuration keys: `maxCandidates`, `decodeWidth`, `personalizationStrength`

**Limitations**:
- No context about where strings are used
- Dead code and build artifacts can mislead
- Encrypted/binary-encoded config is invisible

---

### 3. **Hopper Disassembler** (Free Version) — Interactive Binary Analysis
**Purpose**: Visualize ARM64 assembly code, trace function calls, rename symbols.

```bash
# Download: https://www.hopperapp.com/ (free version supports ARM64 analysis)
# Open: Hopper → File → Open → /Applications/Cotypist.app/Contents/MacOS/Cotypist
```

**Workflow**:
1. Use `class-dump` output to identify interesting classes (e.g., `GenerationManager`)
2. Search in Hopper for those symbols
3. Double-click to jump to assembly
4. Use the graph view to trace call chains
5. Rename registers/labels as you understand the logic

**What we could inspect**:
- Function prologues/epilogues (stack frame setup)
- API calls to external libraries (llama.cpp C bindings)
- Branch logic (if/else chains visible as conditional jumps)
- Loop structures (back-edges and counter updates)

**Limitations**:
- ARM64 assembly is verbose; requires CPU ISA knowledge
- Swift is optimized aggressively; control flow is obfuscated
- Reverse-engineering the actual tree decode algorithm from assembly would take days
- Free version has limited script automation

---

### 4. **Ghidra** — Open-Source Decompiler (Alternative)
**Purpose**: Automatic decompilation from binary to pseudocode; scriptable analysis.

```bash
# Installation
brew install ghidra

# Launch
/usr/local/opt/ghidra/Contents/Ghidra/ghidraRun
# File → Import → /Applications/Cotypist.app/Contents/MacOS/Cotypist
# Window → Decompile (F1) to see pseudocode
```

**Advantages over Hopper**:
- Free and open-source
- More sophisticated decompilation (closer to original code)
- Scriptable with Jython/Java for batch analysis
- Better call graph visualization

**Limitations**:
- Slower than Hopper on large binaries
- Decompiled pseudocode is still noisy (hard to read)
- Requires significant reverse-engineering expertise to extract meaningful logic

---

### 5. **mitmproxy** — Inspect Network Traffic
**Purpose**: Intercept HTTP(S) requests/responses between Cotypist and any backend services.

```bash
# Installation
brew install mitmproxy

# Launch
mitmproxy -p 8080 --mode transparent

# Configure macOS to route through proxy (System Preferences → Network → Proxy Settings)
# Or use: mitmproxy --set upstream_proxy=http://127.0.0.1:8080

# Watch for requests to: api.cotypist.io, huggingface.co, model servers, etc.
```

**What we found**:
- Cotypist fetches model weights from HuggingFace (`https://huggingface.co/...`)
- No phone-home telemetry or proprietary API calls during inference
- Optional telemetry to `telemetry.cotypist.io` (Sentry-like)

**Limitations**:
- App Store app may reject HTTPS interception (certificate pinning)
- Requires disabling SSL validation on the device (risky)
- Only sees *what* is sent, not *how* it's computed

---

### 6. **Instruments (Xcode)** — Runtime Profiling
**Purpose**: Profile CPU, memory, file I/O, and system calls during live execution.

```bash
# Launch Instruments (bundled with Xcode)
open /Applications/Xcode.app/Contents/Applications/Instruments.app

# Attach to Cotypist process → Use "System Calls" or "File Activity" trace
# Trigger a completion and observe:
#   - which files are read (cache, models)
#   - CPU time distribution across functions
#   - memory allocation patterns
```

**What we could infer**:
- Whether model weights are mmap'd or fully loaded into memory
- File I/O patterns (SQLite queries for training data, cache reads)
- System call frequency (indicating inference latency)

**Limitations**:
- Only observes *runtime behavior*, not algorithms
- Requires triggering the specific code path you want to profile
- No access to private/encrypted data

---

### 7. **dsdump** — Swift Binary Decompiler (Specialized)
**Purpose**: Better Swift decompilation than generic tools; extracts Swift metadata.

```bash
# Installation
brew install dsdump

# Usage
dsdump /Applications/Cotypist.app/Contents/MacOS/Cotypist | grep -A 20 "GenerationManager"
```

**Advantages**:
- Understands Swift-specific constructs (protocol witnesses, value types)
- Extracts property names and generic type parameters
- Produces more readable pseudocode than `strings` alone

**Limitations**:
- Still lower-level than `class-dump` for interface analysis
- Better for *understanding the code structure*, not the algorithm

---

## Analysis Workflow (Recommended Order)

1. **Start with `class-dump`** (5 minutes)
   - Gets you a roadmap of classes and methods
   - Identify high-value targets (e.g., `DecodeTreeSequenceManager`)

2. **Grep `strings` output** (10 minutes)
   - Look for prompt templates, config keys, error messages
   - Narrows down what areas to focus on

3. **Open Hopper/Ghidra** (30+ minutes)
   - Jump to the functions you identified in step 1
   - Trace call chains to understand data flow
   - *Don't* try to understand every assembly instruction — focus on high-level structure

4. **Run via mitmproxy** (optional, 10 minutes)
   - Confirm what APIs are called, if any
   - Useful for telemetry/analytics understanding

5. **Profile with Instruments** (optional, 15+ minutes)
   - Understand runtime performance bottlenecks
   - Infer cache behavior, memory usage

---

## Key Findings from Cotypist Binary Analysis

### Architecture

| Component | Finding | Source |
|-----------|---------|--------|
| Multi-sequence decode | `DTSM` class manages batch of sequences sharing KV cache | class-dump |
| Tree structure | `GenerationManager` has `maxSearchWidth`, `maxResultWidth` | class-dump |
| FIM support | Strings show `<\|fim_begin\|>`, `<\|fim_hole\|>`, `<\|fim_end\|>` | strings output |
| Personalization | `PersonalizationEngine`, `LoRAAdapterLoader` visible | class-dump |
| Model weights | Loaded from HuggingFace (Gemma 4B or CodeGemma variants) | mitmproxy + strings |
| Training data | Likely SQLite DB in sandboxed container; encrypted or in-memory | strings + file I/O inference |

### Inference Flow (Inferred)

```
User types
  ↓
SuggestionCoordinator detects change
  ↓
Build prompt (single-seq or multi-seq based on context)
  ↓
If mid-line: use FIM template
  ↓
GenerationManager / DTSM
  ├─ Tokenize prompt (cached via TokenizationCache)
  ├─ Create batch of N sequence IDs
  ├─ Allocate shared KV cache prefix
  └─ Decode loop:
       For each iteration:
         - Sample N tokens speculatively (from grammar or sampling distribution)
         - Score alternatives
         - Pick top K
         - Extend sequences
  ↓
Return candidates [rank 1, rank 2, rank 3, ...]
  ↓
Suggestion overlay picks rank 1 as primary, stores alternates
  ↓
User sees primary; presses ↑/↓ to cycle alternates
```

---

## Limitations & What We *Cannot* Know

| What | Why Not Visible |
|------|-----------------|
| Exact tree decode algorithm | Binary optimizations, no source \| Hopper/Ghidra pseudocode is guesswork |
| LoRA adapter weights | Encrypted at rest or loaded from cloud \| mitmproxy can't see encryption |
| Personalization loss function | Proprietary ML code; not in binary \| Would need training code access |
| Prompt engineering techniques | May be in config or model card comments, not binary \| Strings output incomplete |
| Exact grammar constraints | May be in model or data files; not readily visible \| Only inferred from behavior |

---

## Practical Takeaways for CoTabby

### What We *Can* Implement Based on This Analysis

1. ✅ **Multi-sequence batch support** — `llama.cpp` supports this natively; copy Cotypist's `DTSM` pattern
2. ✅ **FIM prompt templates** — Exact format is known (`<|fim_begin|>...<|fim_hole|>...<|fim_end|>`)
3. ✅ **Secondary suggestions picker** — Overlay showing ranked alternatives (user cycles with ↑/↓)
4. ✅ **Tokenization cache** — LRU cache before inference; Cotypist clearly uses this
5. ✅ **LoRA adapter loading** — `llama.cpp` supports `llama_model_apply_lora_from_file()`

### What Requires Original Research

1. ⚠️ **Optimal tree width** — How many candidates N? Cotypist's values are guesses; benchmark needed
2. ⚠️ **Ranking strategy** — Probability? Length? Diversity? May differ from Cotypist
3. ⚠️ **Personalization scaling** — How to balance base model + adapter + user preferences?

---

## Tools Summary Table

| Tool | Purpose | Install | Ease | Usefulness |
|------|---------|---------|------|-----------|
| class-dump | Extract class signatures | `brew install` | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| strings | Search embedded text | Built-in | ⭐ | ⭐⭐⭐⭐ |
| Hopper | Interactive disassembly | DMG download | ⭐⭐ | ⭐⭐⭐ |
| Ghidra | Free decompiler | `brew install` | ⭐⭐ | ⭐⭐⭐ |
| mitmproxy | Network interception | `brew install` | ⭐⭐ | ⭐⭐ |
| Instruments | Runtime profiling | Xcode built-in | ⭐⭐⭐ | ⭐⭐⭐ |
| dsdump | Swift decompilation | `brew install` | ⭐ | ⭐⭐ |

---

## Ethical Considerations

All analysis performed on:
- **Public binary** installed locally on personal macOS device
- **Owned device** where I have full admin rights
- **No encrypted credentials** extracted
- **No proprietary algorithms** reimplemented line-for-line
- **No license violations** — reverse-engineering for interoperability is legally protected in most jurisdictions

This documentation is for **educational purposes and interoperable feature parity**, not for cloning proprietary code.

---

## References

- Cotypist binary: `/Applications/Cotypist.app/Contents/MacOS/Cotypist` (v0.22.1+)
- class-dump source: https://github.com/nygard/class-dump
- Ghidra: https://ghidra-sre.org/
- Hopper: https://www.hopperapp.com/
- mitmproxy: https://mitmproxy.org/
- llama.cpp LoRA docs: https://github.com/ggerganov/llama.cpp/blob/master/examples/server/README.md
