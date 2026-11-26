# Asset sources

Fonts and OFL licenses are byte-for-byte copies from
`aiur-team/khala` at `eb6665f`, `apps/web/src/brand/fonts/`.
The three woff2 hashes match `apps/web/src/brand/tokens.test.ts` at that commit.

The original logo is copied from `website/public/assets/aiur-logo.png`;
the favicon set and manifest are copied from `website/public/` in this repository.

## Reproduce optimized logos

ImageMagick 7.1.2-27 Q16-HDRI (WebP delegate), from repository root:

```sh
magick packages/aiur-style/assets/aiur-logo.png -filter Lanczos -resize '512x512>' -strip packages/aiur-style/assets/aiur-logo-512.png
magick packages/aiur-style/assets/aiur-logo-512.png -define webp:lossless=true packages/aiur-style/assets/aiur-logo-512.webp
```

The PNG is 149,606 bytes; the lossless WebP is 84,956 bytes.
The longest edge is 512px. Fonts remain under the SIL Open Font License;
the accompanying OFL files contain their copyright notices.

## SHA-256

```text
5c38f7445f3fb122d8cfec099cf9d4efe6a76d6644d0eb98bf3c822d218c8b19  assets/aiur-logo-512.png
0cb376f4ff33c1649c97596d92e0ce529838df75a82acc817bb5d6a8b158f19d  assets/aiur-logo-512.webp
5f3b8f3dfa3c1376c775ede482bbb2048bbc4a9c51fd4535ba826f0ec7ac7482  assets/aiur-logo.png
8de87db505c633edc9b53f473b37c68ad3bf2fe2c681dda1131a9b4d9408fa51  assets/android-chrome-192x192.png
cad46f19aafd763d90d04141c9c75acfbe0005e8f3d6232f1d7625c3196c6de4  assets/android-chrome-512x512.png
69803b1146c7f6ea7a242eb6aae14a9951d058ea4aaf7fcac6fbe0cd54c33ca9  assets/apple-touch-icon.png
f1dd7161e923cd8ef3e28f73564e3255add3932756b118eb36bc37a3274cf6d5  assets/favicon-16x16.png
7eeb7e8034e0613e2984d97bb8b61bd18497e915542359767862e4b6214e5daa  assets/favicon-32x32.png
7e2c794adfa502c40ec7a6a122bf4440d23117d18c579bf891defc5bc3727f01  assets/favicon.ico
c43bd1fc2f36b6d5fba728c62c5e2f130bb022dba187b55093e0c175432bad09  assets/site.webmanifest
d5787a50dde5be6c6daecab9ed459939b1bc37cff0d0e00257eaf1ec2cf4c16c  fonts/Bungee-OFL.txt
4513a7d68c82c053f363075a8aee249d60146f7c0bb7236cd27d721bffd16eeb  fonts/Bungee-Regular.woff2
b2fe5e8987594e9ffd1d2ca52a2f5d73eb8335243893c5d6254b5ad69269591d  fonts/JetBrainsMono-OFL.txt
11038e282dd7cb983dfc4e565017f37a91041c073c8929771fb6e64d27814396  fonts/JetBrainsMono-Variable.woff2
564ce565c371c5e5bbf286006565a7c9aa55a9f56e7ca58d56e05d649dd61a72  fonts/SpaceGrotesk-OFL.txt
cb48953e20ccd61690a20f1d910d333aa3a352e62ac18d3ffc4e0264a3c4aaa4  fonts/SpaceGrotesk-Variable.woff2
```
