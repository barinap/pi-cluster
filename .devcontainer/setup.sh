#!/bin/bash
set -euo pipefail

# Detect architecture
case "$(uname -m)" in
  x86_64)  ARCH="x86_64"; ARCH_ALT="amd64" ;;
  aarch64) ARCH="arm64";  ARCH_ALT="arm64" ;;
  *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

# Packages available via apt
sudo apt-get update
sudo apt-get install -y \
  fd-find \
  ripgrep \
  fzf \
  direnv \
  vim \
  tmux \
  iputils-ping

# Symlink fd-find to fd
sudo ln -sf "$(which fdfind)" /usr/local/bin/fd

# Neovim (latest stable from GitHub)
NEOVIM_VERSION="v0.12.0"
curl -fsSL "https://github.com/neovim/neovim/releases/download/${NEOVIM_VERSION}/nvim-linux-${ARCH}.tar.gz" | sudo tar xz -C /usr/local --strip-components=1

# Lazygit
LAZYGIT_VERSION=$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_linux_${ARCH}.tar.gz" | sudo tar xz -C /usr/local/bin lazygit

# k9s
K9S_VERSION=$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest | grep '"tag_name"' | sed 's/.*"\(.*\)".*/\1/')
curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${ARCH_ALT}.tar.gz" | sudo tar xz -C /usr/local/bin k9s

# Flux CLI
curl -fsSL https://fluxcd.io/install.sh | sudo bash

# Dotfiles
WORKSPACE_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$WORKSPACE_DIR/.tmux.conf" ~/
cp "$WORKSPACE_DIR/.vimrc" ~/

# Direnv hook for zsh
echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc

# LazyVim
git clone https://github.com/LazyVim/starter ~/.config/nvim
rm -rf ~/.config/nvim/.git
