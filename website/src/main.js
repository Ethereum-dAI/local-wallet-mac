import './styles.css';

const downloadUrl = 'https://github.com/Ethereum-dAI/local-wallet/releases/download/v0.1.0/LocalWallet-Demo-macOS-AppleSilicon.zip';
const releaseFileName = 'LocalWallet-Demo-macOS-AppleSilicon.zip';
const repoUrl = 'https://github.com/Ethereum-dAI/local-wallet';

document.querySelector('#app').innerHTML = `
  <main class="page-shell">
    <nav class="nav" aria-label="Primary">
      <a class="brand" href="#top" aria-label="Local Wallet home">
        <span class="brand-mark" aria-hidden="true">LW</span>
        <span>Local Wallet</span>
      </a>
      <div class="nav-links">
        <a href="#how">How it works</a>
        <a href="/docs.html">Docs</a>
        <a href="#download">Download</a>
        <a href="${repoUrl}">GitHub</a>
      </div>
    </nav>

    <section id="top" class="hero" aria-labelledby="title">
      <div class="hero-copy">
        <p class="eyebrow">macOS Sepolia demo</p>
        <h1 id="title">Secure Enclave signing for Kernel smart accounts.</h1>
        <p class="lede">
          Try the current Local Wallet demo: a native macOS app that creates a device-bound key,
          precomputes a Kernel account, builds ERC-4337 UserOperations, and signs locally.
        </p>

        <div class="actions">
          <a class="button primary" href="${downloadUrl}">Download demo</a>
          <a class="button secondary" href="/docs.html">Read library docs</a>
          <a class="button secondary" href="${repoUrl}">GitHub repository</a>
          <a class="button secondary" href="#install">Install notes</a>
        </div>

        <dl class="compatibility" aria-label="Compatibility">
          <div>
            <dt>Target</dt>
            <dd>Apple Silicon</dd>
          </div>
          <div>
            <dt>macOS</dt>
            <dd>14+</dd>
          </div>
          <div>
            <dt>Network</dt>
            <dd>Sepolia only</dd>
          </div>
        </dl>
      </div>

      <div class="demo-card" aria-label="Demo app preview">
        <div class="window-chrome">
          <span></span><span></span><span></span>
        </div>
        <div class="wallet-preview">
          <div class="preview-header">
            <div>
              <p class="preview-kicker">Precomputed account</p>
              <strong>0xb1fe...db7b5f</strong>
            </div>
            <span class="status-pill">Sepolia</span>
          </div>
          <div class="preview-grid">
            <div class="metric">
              <span>State</span>
              <strong>Deployed</strong>
            </div>
            <div class="metric green">
              <span>Balance</span>
              <strong>0.049 ETH</strong>
            </div>
          </div>
          <div class="operation">
            <span class="operation-line wide"></span>
            <span class="operation-line"></span>
            <div class="operation-actions">
              <span>Build draft</span>
              <strong>Send UserOperation</strong>
            </div>
          </div>
          <div class="log-panel">
            <span>[send] signing via Secure Enclave</span>
            <span>[send] bundler accepted UserOperation</span>
            <span>[receipt] included in bundle transaction</span>
          </div>
        </div>
      </div>
    </section>

    <section class="feature-strip" aria-label="Demo capabilities">
      <article>
        <span class="card-index">01</span>
        <h2>Your Mac as hardware wallet</h2>
        <p>The demo creates a non-exportable P-256 key in Secure Enclave using Apple security APIs, then keeps only the public key and metadata outside the enclave.</p>
      </article>
      <article>
        <span class="card-index">02</span>
        <h2>Biometric enclave signing</h2>
        <p>Every UserOperation is signed locally after macOS user presence approval. The private key never leaves the Secure Enclave.</p>
      </article>
      <article>
        <span class="card-index">03</span>
        <h2>Passkey-style Kernel account</h2>
        <p>The P-256 public key is encoded for Kernel's WebAuthn validator, making the precomputed smart account compatible with passkey-style verification.</p>
      </article>
    </section>

    <section id="how" class="section split">
      <div>
        <p class="eyebrow">How it works</p>
        <h2>Local key, Rust helpers, hosted bundler.</h2>
      </div>
      <ol class="steps">
        <li>
          <strong>Bootstrap</strong>
          <span>The app creates or loads the Secure Enclave key and stores wallet metadata locally.</span>
        </li>
        <li>
          <strong>Precompute</strong>
          <span>Rust helpers derive the Kernel initialization data and counterfactual account address.</span>
        </li>
        <li>
          <strong>Compose</strong>
          <span>The demo builds an ETH transfer UserOperation for Ethereum Sepolia.</span>
        </li>
        <li>
          <strong>Sign and submit</strong>
          <span>macOS asks for user presence, signs locally, then the hosted bundler submits the operation.</span>
        </li>
      </ol>
    </section>

    <section id="download" class="download-panel" aria-labelledby="download-title">
      <div>
        <p class="eyebrow">Download</p>
        <h2 id="download-title">Get the current non-notarized demo build.</h2>
        <p>
          The first build is for Apple Silicon Macs on macOS 14 or newer. It is a developer demo,
          not the final wallet product. The source is public so developers can inspect the Rust
          helpers, Swift bridge, and native macOS signing flow.
        </p>
      </div>
      <div class="download-box">
        <span class="file-name">${releaseFileName}</span>
        <a class="button primary full" href="${downloadUrl}">Download macOS demo</a>
        <a class="button ghost full" href="${repoUrl}">View source repository</a>
      </div>
    </section>

    <section id="install" class="section install-grid">
      <article>
        <h2>Install notes</h2>
        <p>
          This early demo is not Developer ID signed or notarized. macOS may block the first launch.
          Right-click the app and choose Open, or use Privacy & Security > Open Anyway.
        </p>
      </article>
      <article>
        <h2>What it is not</h2>
        <p>
          No mainnet mode, no production recovery, no audited wallet guarantees, and no final consumer UX.
          It is a test surface for the local signer and Kernel UserOperation path.
        </p>
      </article>
    </section>
  </main>
`;
