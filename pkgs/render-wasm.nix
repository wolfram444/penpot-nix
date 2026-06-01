{
  stdenv,
  nodejs,
  pnpm,
  cacert,
  penpot-src,
  emscripten,
  rustToolchain,
  rustPlatform,
  python3,
  curl,
  nukeReferences,
}:

let
  version = "2.6.0-develop";
in
stdenv.mkDerivation {
  pname = "penpot-render-wasm";
  inherit version;
  src = penpot-src;

  nativeBuildInputs = [
    nodejs
    pnpm
    cacert
    emscripten
    rustToolchain
    rustPlatform.bindgenHook
    python3
    curl
    nukeReferences
  ];
  dontFixup = true;

  buildPhase = ''
    export HOME=$(pwd)
    export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
    export NODE_ENV=production
    export VERSION=${version}
    export COREPACK_ENABLE_STRICT=0
    export COREPACK_ENABLE_AUTO_PIN=0

    export EMSDK=${emscripten}
    export EM_CONFIG=${emscripten}/share/emscripten/.emscripten

    cd render-wasm

    # Disable corepack since pnpm is provided natively by nixpkgs
    sed -i '/corepack enable/d; /corepack install/d' _build_env

    patchShebangs build
    patchShebangs _build_env

    # Run the native Penpot render-wasm build script.
    # It compiles Rust to Wasm, runs esbuild, and automatically copies 
    # the finalized artifacts into ../frontend/resources/public/js/ and ../frontend/src/app/render_wasm/api/
    ./build
  '';

  installPhase = ''
    mkdir -p $out/public/js/worker
    mkdir -p $out/api

    # Harvest the compiled artifacts that Penpot's script outputted into the frontend folder
    cp -r ../frontend/resources/public/js/render-wasm.js $out/public/js/
    cp -r ../frontend/resources/public/js/render-wasm.wasm $out/public/js/
    cp -r ../frontend/resources/public/js/worker/render.js $out/public/js/worker/
    cp -r ../frontend/src/app/render_wasm/api/shared.js $out/api/

    # Eradicate the strictly embedded Emscripten and Rust stdlib debug paths natively 
    # compiled into the Wasm/JS binaries to safely satisfy the Nix FOD guarantees.
    find $out -type f -exec nuke-refs {} +
  '';

  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = "sha256-0wiZSPJV6tMwTKk74R3enGM8OIpHa2KzCsDubMWd94c=";
}
