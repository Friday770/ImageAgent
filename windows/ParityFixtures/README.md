# macOS Core golden fixtures

These are synthetic test patterns generated from the unchanged Swift core at `677146984a186f3824e01b977c916c21da46a861`. They contain no user images, history, API responses or credentials.

`manifest.json` contains six selection cases with exact source RGBA, vector selection JSON, coverage, ROI and expected composite RGBA for the constant patch color. The cases cover fractional/reverse rectangles, clipped concave and crossed pen contours, a separate fine legacy brush mark, inward feathering and an outside collinear contour that must remain empty. The PNG masks are the original Core alpha masks.

`display-p3.png` and `display-p3.icc` test RGB ICC handling; `transparent.png` tests opaque, semi-transparent and fully transparent pixels. The Windows tests must check geometry against these golden values, output color/profile behavior and exact outside-selection pixel preservation.

Regenerate on macOS from the project root:

```sh
swiftc -parse-as-library -target arm64-apple-macosx14.0 -I Sources/CSQLite Sources/ImageAgentCore/*.swift scripts/windows/generate-parity-fixtures.swift -o artifacts/windows-tools/fixture-generator/generate
artifacts/windows-tools/fixture-generator/generate windows/ParityFixtures
```

Windows builds consume the committed fixtures and do not require Swift.

`orientation-manifest.json` and `orientation-1.tiff` through `orientation-8.tiff` additionally record the original Swift decoder's exact RGBA/dimensions for all eight TIFF orientations in Display P3. Orientations 5–8 swap width and height. These are lossless synthetic TIFFs, not user photographs.
