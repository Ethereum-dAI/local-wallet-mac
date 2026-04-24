import './styles.css';

const repoUrl = 'https://github.com/Ethereum-dAI/local-wallet';

document.querySelector('#app').innerHTML = `
  <main class="docs-shell">
    <nav class="docs-topbar" aria-label="Documentation">
      <a class="brand" href="/" aria-label="Local Wallet home">
        <span class="brand-mark" aria-hidden="true">LW</span>
        <span>Local Wallet</span>
      </a>
      <div class="nav-links">
        <a href="/">Demo page</a>
        <a href="${repoUrl}">GitHub</a>
      </div>
    </nav>

    <header class="docs-hero">
      <p class="eyebrow">Developer documentation</p>
      <h1>Local Wallet libraries</h1>
      <p>
        Reference documentation for the reusable Rust and Swift pieces behind the macOS demo.
        The demo app is only one consumer. The libraries are meant to keep deterministic
        Kernel/WebAuthn account logic reusable outside the native UI.
      </p>
    </header>

    <div class="docs-reference">
      <aside class="docs-toc" aria-label="Documentation table of contents">
        <strong>On this page</strong>
        <a href="#overview">Overview</a>
        <a href="#architecture">Architecture</a>
        <a href="#signature">wallet-signature</a>
        <a href="#kernel">wallet-kernel</a>
        <a href="#swift">swift-bridge</a>
        <a href="#ffi">wallet-ffi</a>
        <a href="#integration">Integration patterns</a>
        <a href="#testing">Testing</a>
      </aside>

      <article class="docs-content">
        <section id="overview" class="doc-block">
          <h2>Overview</h2>
          <p>
            Local Wallet separates the native security boundary from deterministic protocol logic.
            Swift owns Secure Enclave key creation, Keychain lookup, local metadata, UI state, RPC
            requests, and hosted bundler calls. Rust owns byte-exact account and signature helpers:
            UserOperation hashing, Kernel initialization calldata, WebAuthn-compatible payloads,
            signature encoding, and counterfactual account prediction.
          </p>
          <p>
            This split is intentional. Other apps, CLIs, agents, or backend tools should be able to
            reuse the Rust crates without adopting the macOS demo app. Apple-platform apps can use
            the Swift package when they need the same helpers from Swift.
          </p>
        </section>

        <section id="architecture" class="doc-block">
          <h2>Architecture</h2>
          <p>The current stack has four reusable layers.</p>
          <table>
            <thead>
              <tr>
                <th>Layer</th>
                <th>Purpose</th>
                <th>Public surface</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td><code>wallet-signature</code></td>
                <td>ERC-4337 hash and Kernel/WebAuthn signature helpers.</td>
                <td>Rust crate</td>
              </tr>
              <tr>
                <td><code>wallet-kernel</code></td>
                <td>Kernel initialization calldata and precomputed account address helpers.</td>
                <td>Rust crate</td>
              </tr>
              <tr>
                <td><code>wallet-ffi</code></td>
                <td>C ABI used to expose selected Rust helpers to Swift.</td>
                <td>Internal bridge</td>
              </tr>
              <tr>
                <td><code>swift-bridge</code></td>
                <td>Swift package wrapping the internal C ABI for Apple-platform apps.</td>
                <td>Swift package</td>
              </tr>
            </tbody>
          </table>
        </section>

        <section id="signature" class="doc-block">
          <h2>wallet-signature</h2>
          <p>
            <code>wallet-signature</code> is the core protocol crate for UserOperation and WebAuthn
            signature handling. It does not perform networking, does not use async, does not expose
            FFI, and does not hold private keys.
          </p>
          <h3>Use it for</h3>
          <ul>
            <li>Computing EntryPoint v0.7 PackedUserOperation hashes.</li>
            <li>Constructing the WebAuthn signing preimage: authenticator data plus client data hash.</li>
            <li>Normalizing P-256 signatures to low-s before validator submission.</li>
            <li>Encoding the final Kernel/WebAuthn signature bytes for <code>UserOperation.signature</code>.</li>
          </ul>
          <h3>Do not use it for</h3>
          <ul>
            <li>Secure Enclave or passkey key management.</li>
            <li>RPC, bundler, or paymaster calls.</li>
            <li>Wallet metadata persistence.</li>
          </ul>
          <pre><code>cd rust-core
cargo test -p wallet-signature</code></pre>
        </section>

        <section id="kernel" class="doc-block">
          <h2>wallet-kernel</h2>
          <p>
            <code>wallet-kernel</code> contains deterministic Kernel account helpers for a
            WebAuthn-root account. It is the crate to use when a developer needs to precompute the
            smart account address or build the Kernel initialization payload.
          </p>
          <h3>Responsibilities</h3>
          <ul>
            <li>Build the <code>bytes21</code> root validator id from validator type plus address.</li>
            <li>ABI-encode WebAuthn validator data with P-256 public key X/Y and authenticator id hash.</li>
            <li>ABI-encode <code>Kernel.initialize(...)</code> calldata.</li>
            <li>Compute the CREATE2 counterfactual address using the Kernel factory and implementation.</li>
          </ul>
          <pre><code>use wallet_kernel::predict_kernel_account_address;

let address = predict_kernel_account_address(
    factory,
    implementation,
    webauthn_validator,
    pub_key_x,
    pub_key_y,
    authenticator_id_hash,
    salt,
);</code></pre>
        </section>

        <section id="swift" class="doc-block">
          <h2>swift-bridge</h2>
          <p>
            <code>swift-bridge</code> is the Apple-platform SDK surface. It wraps the internal FFI
            layer so Swift apps can call the deterministic Rust helpers while keeping Secure Enclave
            signing, Keychain access, and UI prompts in Swift.
          </p>
          <h3>Main calls</h3>
          <ul>
            <li><code>WalletSignature.computeUserOpHash(...)</code> returns the 32-byte UserOperation hash.</li>
            <li><code>WalletSignature.computeSigningPreimage(...)</code> returns the 69-byte WebAuthn preimage signed by Secure Enclave.</li>
            <li><code>WalletSignature.normaliseLowS(...)</code> adjusts P-256 signatures for validator compatibility.</li>
            <li><code>WalletSignature.abiEncodeSignature(...)</code> returns final Kernel/WebAuthn signature bytes.</li>
            <li><code>WalletSignature.predictKernelAccountAddress(...)</code> exposes account precompute to Swift.</li>
          </ul>
          <pre><code>./scripts/build-ffi.sh
cd swift-bridge
swift test</code></pre>
        </section>

        <section id="ffi" class="doc-block">
          <h2>wallet-ffi</h2>
          <p>
            <code>wallet-ffi</code> is a C-compatible bridge for <code>swift-bridge</code>. It is
            deliberately not the primary public SDK because direct consumers must handle raw pointers,
            fixed output buffers, integer status codes, and explicit buffer release.
          </p>
          <p>
            If a developer is writing Rust, they should use <code>wallet-signature</code> and
            <code>wallet-kernel</code> directly. If they are writing Swift, they should use
            <code>swift-bridge</code>. The FFI layer exists only where a language boundary requires it.
          </p>
        </section>

        <section id="integration" class="doc-block">
          <h2>Integration patterns</h2>
          <h3>Rust apps</h3>
          <p>
            Use the Rust crates directly. This is the cleanest path for CLIs, daemons, local agents,
            backend services, or other Rust wallets.
          </p>
          <h3>Swift/macOS apps</h3>
          <p>
            Use <code>swift-bridge</code> for protocol helpers and keep private-key operations in
            Secure Enclave through Apple APIs. This is the pattern used by the demo app.
          </p>
          <h3>TypeScript or Python tools</h3>
          <p>
            The current repo does not expose first-class TypeScript or Python packages. The pragmatic
            route is to keep the Rust crates as the source of truth, then add a small CLI or future
            language bindings on top when there is a concrete integration target.
          </p>
        </section>

        <section id="testing" class="doc-block">
          <h2>Testing checklist</h2>
          <p>
            The protocol helpers are deterministic, so most behavior should be validated with unit
            tests and vectors before testing the full native app.
          </p>
          <pre><code>cd rust-core
cargo test -p wallet-signature
cargo test -p wallet-kernel

cd ..
./scripts/build-ffi.sh
cd swift-bridge
swift test</code></pre>
          <p>
            For app-level validation, run the macOS demo on Sepolia, inspect the debug logs, build a
            UserOperation draft, sign via Secure Enclave, submit through the hosted bundler, and wait
            for the receipt polling path to complete.
          </p>
        </section>
      </article>
    </div>
  </main>
`;
