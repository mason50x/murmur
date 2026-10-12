# Third-party notices

Murmur is MIT licensed (see [LICENSE](LICENSE)). It includes or downloads the following, each under
its own license.

## Included in the app

- **[FluidAudio](https://github.com/FluidInference/FluidAudio)** — Apache License 2.0.
  Includes NeMo text processing and other components listed in its
  [ThirdPartyLicenses](https://github.com/FluidInference/FluidAudio/tree/main/ThirdPartyLicenses).
- **[Sparkle](https://github.com/sparkle-project/Sparkle)** — MIT License, with bundled components
  under their own permissive licenses ([LICENSE](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE)).

## Downloaded at first launch

The speech model you choose is downloaded from Hugging Face; it isn't part of this repository or
the app download.

- **Parakeet Unified EN 0.6B** — NVIDIA, under the
  [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/).
  Core ML conversion by FluidInference
  ([parakeet-unified-en-0.6b-coreml](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml), CC BY 4.0).
- **Phonon-2** — Fermion Research ([Phonon-2](https://huggingface.co/FermionResearch/Phonon-2), CC BY 4.0),
  a retraining of NVIDIA Parakeet TDT 0.6B v3. Core ML conversion by FluidInference
  ([phonon-2-coreml](https://huggingface.co/FluidInference/phonon-2-coreml), CC BY 4.0).
