#!/usr/bin/env bash
# Pasang kustomize, kubeconform, actionlint ke ~/bin (linux/amd64).
# Idempoten: alat yang sudah terpasang dengan versi sama dilewati.
# Ganti versi lewat env, mis.: KUSTOMIZE_VERSION=5.5.0 ./install-infra-tools.sh
set -euo pipefail

KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-5.4.3}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-0.6.7}"
ACTIONLINT_VERSION="${ACTIONLINT_VERSION:-1.7.1}"

BIN_DIR="${BIN_DIR:-$HOME/bin}"
ARCH="amd64"
OS="linux"

mkdir -p "$BIN_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

# verify <berkas> <berkas-checksum> <nama-aset-di-checksum>
verify() {
  local file="$1" sums="$2" name="$3" want got
  want="$(grep -E "[[:space:]]\*?${name}\$" "$sums" | awk '{print $1}' | head -n1)"
  [ -n "$want" ] || { echo "checksum untuk $name tidak ditemukan" >&2; exit 1; }
  got="$(sha256sum "$file" | awk '{print $1}')"
  [ "$want" = "$got" ] || { echo "CHECKSUM TIDAK COCOK untuk $name" >&2; exit 1; }
  echo "  checksum OK: $name"
}

# install <nama> <versi> <perintah-cek-versi> <fungsi-unduh>
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

# Tambahkan ~/bin ke PATH di ~/.bashrc kalau belum ada.
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    if ! grep -qs 'export PATH="\$HOME/bin:\$PATH"' "$HOME/.bashrc"; then
      echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
      echo "Menambahkan ~/bin ke PATH di ~/.bashrc (buka shell baru atau: source ~/.bashrc)"
    fi
    export PATH="$BIN_DIR:$PATH"
    ;;
esac

echo
echo "Hasil:"
kustomize version
kubeconform -v
actionlint -version | head -n1
