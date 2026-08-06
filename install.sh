#!/usr/bin/env bash

set -euo pipefail

REPOSITORY="${CHERRY_CLI_REPOSITORY:-CHENJIAMIAN/cherry-studio-cli}"
REF="${CHERRY_CLI_REF:-main}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
INSTALL_DIRECTORY="${CHERRY_CLI_INSTALL_DIRECTORY:-$DATA_HOME/cherry-studio-cli}"
BIN_DIRECTORY="${CHERRY_CLI_BIN_DIRECTORY:-$HOME/.local/bin}"

fail() {
  printf 'Cherry Studio CLI installer: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少所需命令：$1"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

detect_platform() {
  case "$(uname -s)" in
    Darwin)
      PLATFORM='osx'
      ;;
    Linux)
      PLATFORM='linux'
      ;;
    *)
      fail "不支持的系统：$(uname -s)。此脚本支持 macOS、Linux 和 WSL2。"
      ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64)
      ARCHITECTURE='x64'
      ;;
    arm64|aarch64)
      ARCHITECTURE='arm64'
      ;;
    *)
      fail "不支持的 CPU 架构：$(uname -m)"
      ;;
  esac
}

find_pwsh() {
  local candidate major_version
  if command -v pwsh >/dev/null 2>&1; then
    candidate="$(command -v pwsh)"
    major_version="$("$candidate" -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.Major' 2>/dev/null || true)"
    if [[ "$major_version" =~ ^[0-9]+$ && "$major_version" -ge 7 ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 1
}

install_portable_pwsh() {
  local release_json version archive_name archive_url runtime_base runtime_directory staging_directory temporary_directory
  require_command curl
  require_command tar
  require_command awk
  require_command sed

  release_json="$(curl -fsSL --retry 3 https://api.github.com/repos/PowerShell/PowerShell/releases/latest)"
  version="$(printf '%s\n' "$release_json" | awk -F '"' '/"tag_name"/ { print $4; exit }' | sed 's/^v//')"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || fail '无法解析最新 PowerShell 版本。'

  archive_name="powershell-${version}-${PLATFORM}-${ARCHITECTURE}.tar.gz"
  archive_url="https://github.com/PowerShell/PowerShell/releases/download/v${version}/${archive_name}"
  runtime_base="${DATA_HOME}/cherry-studio-cli/runtime"
  runtime_directory="${runtime_base}/powershell-${version}-${PLATFORM}-${ARCHITECTURE}"

  if [[ -x "${runtime_directory}/pwsh" ]]; then
    PWSH_EXECUTABLE="${runtime_directory}/pwsh"
    return
  fi

  temporary_directory="$(mktemp -d)"
  RUNTIME_TEMPORARY_DIRECTORY="$temporary_directory"
  staging_directory="${runtime_directory}.staging-$$"
  RUNTIME_STAGING_DIRECTORY="$staging_directory"

  printf '未检测到 PowerShell 7，正在下载官方便携版 %s...\n' "$archive_name"
  curl -fsSL --retry 3 "$archive_url" -o "${temporary_directory}/${archive_name}"
  mkdir -p "$runtime_base"
  rm -rf -- "$staging_directory"
  mkdir -p "$staging_directory"
  tar -xzf "${temporary_directory}/${archive_name}" -C "$staging_directory"
  [[ -f "${staging_directory}/pwsh" ]] || fail 'PowerShell 归档中未找到 pwsh。'
  chmod +x "${staging_directory}/pwsh"

  if [[ -e "$runtime_directory" ]]; then
    rm -rf -- "$runtime_directory"
  fi
  mv "$staging_directory" "$runtime_directory"
  RUNTIME_STAGING_DIRECTORY=''
  rm -rf -- "$temporary_directory"
  RUNTIME_TEMPORARY_DIRECTORY=''
  PWSH_EXECUTABLE="${runtime_directory}/pwsh"
}

resolve_pwsh() {
  if PWSH_EXECUTABLE="$(find_pwsh)"; then
    return
  fi

  install_portable_pwsh
}

local_source_root() {
  local script_directory
  script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
  if [[ -n "$script_directory" && -f "${script_directory}/cherry.ps1" && -f "${script_directory}/cherry-client.ps1" && -f "${script_directory}/scripts/Connect-CLIProxyAPI.ps1" ]]; then
    printf '%s\n' "$script_directory"
    return 0
  fi

  return 1
}

download_source_root() {
  local temporary_directory archive source_root candidate
  require_command curl
  require_command tar

  [[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "无效的 GitHub 仓库：$REPOSITORY"
  [[ -n "$REF" ]] || fail 'GitHub ref 不能为空。'

  temporary_directory="$(mktemp -d)"
  TEMPORARY_SOURCE_DIRECTORY="$temporary_directory"
  archive="${temporary_directory}/source.tar.gz"
  printf '正在从 %s@%s 下载 Cherry Studio CLI...\n' "$REPOSITORY" "$REF" >&2
  curl -fsSL --retry 3 "https://api.github.com/repos/${REPOSITORY}/tarball/${REF}" -o "$archive"
  tar -xzf "$archive" -C "$temporary_directory"
  source_root=''
  for candidate in "${temporary_directory}"/*; do
    if [[ -d "$candidate" && -f "${candidate}/cherry.ps1" && -f "${candidate}/cherry-client.ps1" && -f "${candidate}/scripts/Connect-CLIProxyAPI.ps1" ]]; then
      source_root="$candidate"
      break
    fi
  done
  [[ -n "$source_root" ]] || fail "下载的归档不包含有效的 Cherry Studio CLI：${REPOSITORY}@${REF}"
  SOURCE_ROOT="$source_root"
}

copy_application_files() {
  local source_root="$1" destination_root="$2" file_name
  for file_name in cherry.ps1 cherry-client.ps1; do
    [[ -f "${source_root}/${file_name}" ]] || fail "安装源缺少运行时文件：${file_name}"
    cp "${source_root}/${file_name}" "${destination_root}/${file_name}"
  done

  [[ -d "${source_root}/scripts" ]] || fail '安装源缺少 scripts 目录。'
  cp -R "${source_root}/scripts" "${destination_root}/scripts"

  for file_name in LICENSE THIRD_PARTY_NOTICES.md install.ps1 install.sh; do
    if [[ -f "${source_root}/${file_name}" ]]; then
      cp "${source_root}/${file_name}" "${destination_root}/${file_name}"
    fi
  done
}

install_application() {
  local source_root="$1" parent_directory staging_directory backup_directory
  parent_directory="$(dirname -- "$INSTALL_DIRECTORY")"
  mkdir -p "$parent_directory"

  if [[ -e "$INSTALL_DIRECTORY" && ! -f "${INSTALL_DIRECTORY}/cherry.ps1" && "${CHERRY_CLI_FORCE:-0}" != '1' ]]; then
    fail "安装目录已存在且不属于 Cherry Studio CLI：${INSTALL_DIRECTORY}。确认替换后请设置 CHERRY_CLI_FORCE=1。"
  fi

  staging_directory="${parent_directory}/.cherry-studio-cli-staging-$$"
  APPLICATION_STAGING_DIRECTORY="$staging_directory"
  backup_directory="${parent_directory}/.cherry-studio-cli-backup-$$"
  rm -rf -- "$staging_directory"
  mkdir -p "$staging_directory"
  copy_application_files "$source_root" "$staging_directory"
  [[ -f "${staging_directory}/cherry.ps1" ]] || fail '安装暂存目录校验失败。'

  if [[ -e "$INSTALL_DIRECTORY" ]]; then
    rm -rf -- "$backup_directory"
    mv "$INSTALL_DIRECTORY" "$backup_directory"
  fi

  if ! mv "$staging_directory" "$INSTALL_DIRECTORY"; then
    if [[ -e "$backup_directory" ]]; then
      mv "$backup_directory" "$INSTALL_DIRECTORY"
    fi
    fail '替换安装目录失败。'
  fi
  APPLICATION_STAGING_DIRECTORY=''
  rm -rf -- "$backup_directory"
}

write_launcher() {
  local launcher_path existing_content
  mkdir -p "$BIN_DIRECTORY"
  launcher_path="${BIN_DIRECTORY}/cherry"

  if [[ -e "$launcher_path" ]]; then
    existing_content="$(cat "$launcher_path")"
    if [[ "$existing_content" != *'cherry.ps1'* && "${CHERRY_CLI_FORCE:-0}" != '1' ]]; then
      fail "已存在非 Cherry Studio CLI 的命令启动器：${launcher_path}。确认替换后请设置 CHERRY_CLI_FORCE=1。"
    fi
  fi

  {
    printf '%s\n' '#!/usr/bin/env sh'
    printf 'exec %s -NoLogo -NoProfile -File %s "$@"\n' "$(shell_quote "$PWSH_EXECUTABLE")" "$(shell_quote "${INSTALL_DIRECTORY}/cherry.ps1")"
  } > "$launcher_path"
  chmod +x "$launcher_path"
}

add_bin_directory_to_profile() {
  local profile marker path_line
  case "${SHELL:-}" in
    */zsh)
      profile="${HOME}/.zshrc"
      ;;
    */bash)
      profile="${HOME}/.bashrc"
      ;;
    *)
      profile="${HOME}/.profile"
      ;;
  esac

  marker='# Added by Cherry Studio CLI installer'
  if [[ -f "$profile" ]] && grep -Fqx "$marker" "$profile"; then
    return
  fi

  path_line="export PATH=$(shell_quote "$BIN_DIRECTORY"):\$PATH"
  {
    printf '\n%s\n' "$marker"
    printf '%s\n' "$path_line"
  } >> "$profile"
}

cleanup() {
  if [[ -n "${TEMPORARY_SOURCE_DIRECTORY:-}" && -d "$TEMPORARY_SOURCE_DIRECTORY" ]]; then
    rm -rf -- "$TEMPORARY_SOURCE_DIRECTORY"
  fi
  if [[ -n "${RUNTIME_TEMPORARY_DIRECTORY:-}" && -d "$RUNTIME_TEMPORARY_DIRECTORY" ]]; then
    rm -rf -- "$RUNTIME_TEMPORARY_DIRECTORY"
  fi
  if [[ -n "${RUNTIME_STAGING_DIRECTORY:-}" && -d "$RUNTIME_STAGING_DIRECTORY" ]]; then
    rm -rf -- "$RUNTIME_STAGING_DIRECTORY"
  fi
  if [[ -n "${APPLICATION_STAGING_DIRECTORY:-}" && -d "$APPLICATION_STAGING_DIRECTORY" ]]; then
    rm -rf -- "$APPLICATION_STAGING_DIRECTORY"
  fi
}

main() {
  local source_root
  require_command curl
  detect_platform
  resolve_pwsh

  if source_root="$(local_source_root)"; then
    printf '正在从本地源码安装 Cherry Studio CLI：%s\n' "$source_root"
  else
    download_source_root
    source_root="$SOURCE_ROOT"
  fi

  install_application "$source_root"
  write_launcher
  add_bin_directory_to_profile

  printf 'Cherry Studio CLI 已安装到：%s\n' "$INSTALL_DIRECTORY"
  printf '命令启动器：%s/cherry\n' "$BIN_DIRECTORY"
  printf '请重新打开终端后运行 cherry help。当前终端可直接运行：%s/cherry help\n' "$BIN_DIRECTORY"
  printf '使用模型前，请先在 Cherry Studio 中启动 API Server 并配置 CHERRY_STUDIO_API_KEY。\n'
}

TEMPORARY_SOURCE_DIRECTORY=''
RUNTIME_TEMPORARY_DIRECTORY=''
RUNTIME_STAGING_DIRECTORY=''
APPLICATION_STAGING_DIRECTORY=''
SOURCE_ROOT=''
trap cleanup EXIT
main "$@"
