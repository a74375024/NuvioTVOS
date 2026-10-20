# Vendored playback dependencies

## AetherEngine (pin 7.42.0)

Local pin of [AetherEngine 7.42.0](https://github.com/superuser404notfound/AetherEngine/releases/tag/7.42.0) with imports rewritten to the namespaced FFmpeg modules below and Nuvio's host integration patches retained. This release also avoids Atmos-confirmation reads on sources limited to one request, and adds host-owned display-criteria handling.

Retain the local spatial-bridge patch that reports persistent APAC encoding failures independently of successful TrueHD decoding, along with its regression tests. The patch is merged with the 7.40 bed-split renderer and its telemetry reporting.

Nuvio also retains its supplemental-codecs guard for non-Dolby-Vision displays, including the upstream Profile 7 to Profile 8.1 conversion. Explicit host DV assertions still enable the guarded route. The tagged API, architecture, and format docs are included for upstream documentation-consistency tests.

## FFmpegBuild 3.7.1 (namespaced upstream)

Local pin of [FFmpegBuild 3.7.1](https://github.com/superuser404notfound/FFmpegBuild/tree/3.7.1). The upstream release ships the nine dynamic frameworks and SwiftPM targets under the `AetherLib*` namespace so they can embed next to MPVKit’s `Libav*` stack in the same app binary. The umbrella product is `AetherFFmpegBuild`.

| Upstream module | Nuvio module / framework |
|---|---|
| Libavcodec | AetherLibavcodec |
| Libavformat | AetherLibavformat |
| Libavutil | AetherLibavutil |
| Libswresample | AetherLibswresample |
| Libswscale | AetherLibswscale |
| Libavfilter | AetherLibavfilter |
| Libdav1d | AetherLibdav1d |
| Libzimg | AetherLibzimg |
| Libzvbi | AetherLibzvbi |

### Refreshing from upstream

1. Clone upstream FFmpegBuild at the desired tag into a temp dir.
2. For 3.0.0 and later, copy the already-namespaced `AetherLib*.xcframework` trees directly; do not run `namespace_ffmpegbuild.py` on them.
3. For older unprefixed releases, restore `Lib*.xcframework` trees and run `python3 Vendor/namespace_ffmpegbuild.py` once.
4. Rebase AetherEngine and retain its `../FFmpegBuild` path dependency and `import AetherLib*` names.

Keep the AetherEngine patch surface minimal so rebases stay manageable.

The Nuvio host offers an off-by-default setting for TrueHD Atmos and DTS:X spatial rendering to 9.1.6 APAC. LibTrueHD and LibDTSX are pinned to 3.0.0; APAC rendering requires tvOS 26 or later and a supported 48 kHz VOD source. The app bundles their notices and license texts under `tvosApp/NuvioTV/Resources/AudioLicenses`. TrueHD uses the source's channel presentation split into a speaker bed; DTS:X 3.0 renders its standard presentation and falls back for object presentations. The engine retains its ordinary audio bridge for other content, including ordinary DTS-HD MA.
