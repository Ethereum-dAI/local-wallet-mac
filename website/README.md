# Local Wallet Website

Vite website for the Local Wallet macOS demo download page and developer documentation.

The page is intentionally simple to edit, but it is no longer a placeholder. It explains what the demo does, what it does not provide, the supported macOS target, and the non-notarized install caveat.

The website has two pages:

- `index.html` is the public demo/download landing page.
- `docs.html` is the documentation page for `wallet-signature`, `wallet-kernel`, `swift-bridge`, and the internal `wallet-ffi` bridge.

## Development

```bash
npm install
npm run dev
```

## Build

```bash
npm run build
```

The download button is currently a placeholder. Update `src/main.js` after uploading the demo zip to GitHub Releases or another host.

Expected demo artifact:

```text
LocalWallet-Demo-macOS-AppleSilicon.zip
```

Before publishing, update:

- `downloadUrl` in `src/main.js`
