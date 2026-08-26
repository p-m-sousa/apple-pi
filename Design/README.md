# ApplePi branding

`AppIcon.png` is the canonical 1024×1024 source artwork for the ApplePi app
icon and in-app brand mark.

Regenerate the asset-catalog exports from the repository root with:

```sh
./script/generate_brand_assets.swift Design/AppIcon.png .
```

The generator writes the macOS app-icon sizes to `AppIcon.appiconset` and the
1x/2x in-app mark to `ApplePiMark.imageset`. It applies the shared transparent
rounded-square mask while preserving the source artwork.
