# Third-party notices

## Koharu

The patch under `patches/` is a downstream modification of [Koharu](https://github.com/mayocream/koharu) at commit `a81c5829ea99a45e04580ff97fd6affa81b2db34`. Koharu is distributed under the Apache License 2.0 or MIT License. The corresponding license texts are included as `LICENSE-APACHE` and `LICENSE-MIT`.

Koharu source code is not vendored in this repository. The operator obtains it directly from its upstream repository before applying the patch.

## Hy-MT2-7B

The optional download script references `tencent/Hy-MT2-7B` at revision `9b0eb4e8f001def3e5ff6469a0ac96fdb39ec223`. Its lock entry records the Apache License 2.0. Model files are downloaded separately and are not distributed by this repository.

## Qwen runtime and weights

No Qwen runtime, launcher, or model weights are distributed here. The operator supplies an OpenAI-compatible server, lifecycle implementation, model, and any licenses or notices required by those separately obtained components.

## Fonts

Font family names appear only as configurable typography roles. Font files are not included. Operators are responsible for installing and licensing the fonts they choose to use.
