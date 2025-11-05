# Metal Backend Requirements (2025-11-03)

## Operating System
- Minimum macOS version: 10.15 (Catalina) to align with current kitty support and ensure modern Metal toolchain availability.
- CAMetalLayer and MTLDevice APIs require macOS 10.11+, but we target 10.15+ to match deployment baseline.

## Hardware
- GPU must support Metal (all Apple Silicon and most Intel/AMD Macs from 2012 onward).
- At runtime, verify `MTLCreateSystemDefaultDevice()` and ensure the device supports `MTLGPUFamilyMac1` or newer.
- Multi-GPU Macs should respect automatic graphics switching; choose high-performance GPU when available.

## SDK & Tooling
- Xcode Command Line Tools with Metal compiler (`xcrun metal`, `xcrun metallib`).
- macOS SDK version 13.0 or newer recommended for modern Metal features and validation layers.

## Runtime Checks
- Implement startup guard: if `MTLCreateSystemDefaultDevice()` returns nil, fallback to OpenGL with warning.
- Log device name, feature sets (`supportsFamily:` APIs) for diagnostics.

## Testing Hardware Matrix
- Apple Silicon (M1/M2).
- Intel Macs with discrete AMD GPU.
- Intel Macs with integrated Intel GPU supporting Metal.

