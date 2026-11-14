#!/usr/bin/env bash
# Pasang kustomize, kubeconform, actionlint ke ~/.local/bin (override: BIN_DIR).
# Mendukung Linux dan macOS (amd64/arm64); OS/arch dideteksi dari uname.
# Idempoten: alat yang sudah terpasang dengan versi sama dilewati.
# Ganti versi lewat env, mis.: KUSTOMIZE_VERSION=5.5.0 ./install-infra-tools.sh
set -euo pipefail

# Samakan KUSTOMIZE_VERSION dengan .github/workflows/ci.yml (env KUSTOMIZE_VERSION)
# supaya hasil validasi lokal = hasil CI. kubeconform & actionlint tidak dipatok CI.
KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-5.3.0}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-0.6.7}"
ACTIONLINT_VERSION="${ACTIONLINT_VERSION:-1.7.1}"

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

case "$(uname -s)" in
  Linux)  OS="linux" ;;
  Darwin) OS="darwin" ;;
  *) echo "OS tidak didukung: $(uname -s) (hanya Linux dan macOS)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64)        ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) echo "Arsitektur tidak didukung: $(uname -m) (hanya amd64 dan arm64)" >&2; exit 1 ;;
esac

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  echo "sha256sum atau shasum tidak ditemukan" >&2; exit 1
fi

mkdir -p "$BIN_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

# verify <berkas> <berkas-checksum> <nama-aset-di-checksum>
verify() {
  local file="$1" sums="$2" name="$3" want got
  want="$(grep -E "[[:space:]]\*?${name}\$" "$sums" | awk '{print $1}' | head -n1)"
  [ -n "$want" ] || { echo "checksum untuk $name tidak ditemukan" >&2; exit 1; }
  got="$(sha256 "$file")"
  [ "$want" = "$got" ] || { echo "CHECKSUM TIDAK COCOK untuk $name" >&2; exit 1; }
  echo "  checksum OK: $name"
}

# need <nama> <versi> [argumen-cek-versi]
# Return 0 kalau alat perlu dipasang; return 1 kalau sudah terpasang dengan versi itu.
# Argumen ketiga default "version" (kustomize); kubeconform: -v; actionlint: -version.
need() {
  local tool="$1" ver="$2"
  if [ -x "$BIN_DIR/$tool" ] && "$BIN_DIR/$tool" ${3:-version} 2>&1 | grep -q "$ver"; then
    echo "$tool $ver sudah terpasang, dilewati"
    return 1
  fi
  echo "Memasang $tool $ver ..."
}

if need kustomize "$KUSTOMIZE_VERSION" version; then
  base="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}"
  asset="kustomize_v${KUSTOMIZE_VERSION}_${OS}_${ARCH}.tar.gz"
  fetch "$base/$asset" "$TMP/$asset"
  fetch "$base/checksums.txt" "$TMP/kustomize.sums"
  verify "$TMP/$asset" "$TMP/kustomize.sums" "$asset"
  tar -xzf "$TMP/$asset" -C "$TMP" kustomize
  install -m 0755 "$TMP/kustomize" "$BIN_DIR/kustomize"
fi

if need kubeconform "$KUBECONFORM_VERSION" -v; then
  base="https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}"
  asset="kubeconform-${OS}-${ARCH}.tar.gz"
  fetch "$base/$asset" "$TMP/$asset"
  fetch "$base/CHECKSUMS" "$TMP/kubeconform.sums"
  verify "$TMP/$asset" "$TMP/kubeconform.sums" "$asset"
  tar -xzf "$TMP/$asset" -C "$TMP" kubeconform
  install -m 0755 "$TMP/kubeconform" "$BIN_DIR/kubeconform"
fi

if need actionlint "$ACTIONLINT_VERSION" -version; then
  base="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}"
  asset="actionlint_${ACTIONLINT_VERSION}_${OS}_${ARCH}.tar.gz"
  fetch "$base/$asset" "$TMP/$asset"
  fetch "$base/actionlint_${ACTIONLINT_VERSION}_checksums.txt" "$TMP/actionlint.sums"
  verify "$TMP/$asset" "$TMP/actionlint.sums" "$asset"
  tar -xzf "$TMP/$asset" -C "$TMP" actionlint
  install -m 0755 "$TMP/actionlint" "$BIN_DIR/actionlint"
fi

# Jangan ubah rc file; cukup beri instruksi PATH kalau BIN_DIR belum ada di PATH.
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    echo "$BIN_DIR belum ada di PATH. Tambahkan ke rc file shell Anda"
    echo "(~/.bashrc untuk bash, ~/.zshrc untuk zsh):"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    export PATH="$BIN_DIR:$PATH"
    ;;
esac

echo
echo "Hasil:"
kustomize version
kubeconform -v
actionlint -version | head -n1
