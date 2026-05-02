# Local Wallet Website

Vite website for the Local Wallet macOS demo download page and developer documentation.

The page is intentionally simple to edit, but it is no longer a placeholder. It explains what the demo does, what it does not provide, the supported macOS target, and the non-notarized install caveat.

The website has two pages:

- `index.html` is the public demo/download landing page.
- `docs.html` is the documentation page for `wallet-signature`, `wallet-kernel`, `swift-bridge`, and the internal `wallet-ffi` bridge.

The local `wallet-node` daemon is documented in the repository READMEs and internal tracker docs. It is not currently presented as a public website/download surface.

## Development

```bash
npm install
npm run dev
```

## Build

```bash
npm run build
```

The download button points to the latest published demo zip on GitHub Releases. Update `downloadUrl` in `src/main.js` when publishing a newer release.

Expected demo artifact:

```text
LocalWallet-Demo-macOS-AppleSilicon.zip
```

When publishing a newer release, update:

- `downloadUrl` in `src/main.js`
