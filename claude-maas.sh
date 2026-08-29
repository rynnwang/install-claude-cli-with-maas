#!/usr/bin/env bash
#
# claude-maas.sh
# One-click installer & manager for Claude Code CLI + a MaaS (Anthropic-compatible)
# endpoint, with an interactive menu inspired by fscarmen's sing-box script.
#
# First run (via curl | bash) shows the menu and can install itself as the
# `claude-maas` command so you can re-open this menu any time.
#
# Repo: https://github.com/rynnwang/install-claude-cli-with-maas
# License: MIT
#
# NOTE: pipefail only; we deliberately do NOT use `set -e` because this is an
# interactive menu where individual commands are expected to fail sometimes.
set -o pipefail

VERSION="1.0.0"

# --------------------------------------------------------------------------- #
# Constants / paths
# --------------------------------------------------------------------------- #
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-maas"
CONFIG_FILE="$CONFIG_DIR/config.env"
SELF_INSTALL_PATH="$HOME/.local/bin/claude-maas"
CLAUDE_SETTINGS_DIR="$HOME/.claude"
CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_DIR/settings.json"

MODELS_FILE="$CONFIG_DIR/models.txt"

MARK_BEGIN="# >>> claude-maas >>>"
MARK_END="# <<< claude-maas <<<"

# Built-in MaaS presets: key|显示名|ANTHROPIC_BASE_URL|获取 Key / 文档地址
# 仅为便捷起见预置；各家地址可能调整，以对应平台官方文档为准。
PRESETS=(
  "anthropic|Anthropic 官方|https://api.anthropic.com|https://console.anthropic.com/settings/keys"
  "wanjie|万界方舟 WanJie Ark|https://maas-openapi.wanjiedata.com/api/anthropic|https://www.wjark.com/center/api-key"
  "deepseek|DeepSeek|https://api.deepseek.com/anthropic|https://platform.deepseek.com/api_keys"
  "moonshot|月之暗面 Kimi / Moonshot|https://api.moonshot.cn/anthropic|https://platform.moonshot.cn/console/api-keys"
  "zhipu|智谱 GLM / BigModel|https://open.bigmodel.cn/api/anthropic|https://open.bigmodel.cn/usercenter/apikeys"
  "custom|自定义 / 其它|-|-"
)

# Managed environment keys. Only these are ever written or removed by this tool.
MANAGED_KEYS=(
  ANTHROPIC_BASE_URL
  ANTHROPIC_AUTH_TOKEN
  ANTHROPIC_API_KEY
  ANTHROPIC_MODEL
  ANTHROPIC_SMALL_FAST_MODEL
  ANTHROPIC_DEFAULT_OPUS_MODEL
  ANTHROPIC_DEFAULT_SONNET_MODEL
  ANTHROPIC_DEFAULT_HAIKU_MODEL
  API_TIMEOUT_MS
  CLAUDE_CODE_MAX_OUTPUT_TOKENS
)

# --------------------------------------------------------------------------- #
# Colors
# --------------------------------------------------------------------------- #
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""
fi

info()  { printf '%s\n' "${C_CYAN}[*]${C_RESET} $*"; }
ok()    { printf '%s\n' "${C_GREEN}[+]${C_RESET} $*"; }
warn()  { printf '%s\n' "${C_YELLOW}[!]${C_RESET} $*" >&2; }
err()   { printf '%s\n' "${C_RED}[x]${C_RESET} $*" >&2; }
hr()    { printf '%s\n' "${C_DIM}------------------------------------------------------------${C_RESET}"; }

pause() { printf '\n%s' "${C_DIM}按回车返回菜单... ${C_RESET}"; read -r _ || true; }

# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #
has_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

# Read a value from an existing config.env (KEY='value' lines). Prints nothing if
# absent. We source it in a subshell for correct quote handling, but first unset
# the managed keys so an inherited environment variable of the same name can't
# leak in and be mistaken for a value that lives in the file.
config_get() {
  local key="$1"
  [ -f "$CONFIG_FILE" ] || return 0
  # shellcheck disable=SC1090
  (
    unset $(printf '%s ' "${MANAGED_KEYS[@]}") 2>/dev/null || true
    set -a; . "$CONFIG_FILE" >/dev/null 2>&1 || true; set +a
    printf '%s' "${!key-}"
  )
}

# Prompt with a default; echoes the result.
ask() {
  local prompt="$1" default="${2-}" reply
  if [ -n "$default" ]; then
    printf '%s' "$prompt [${C_DIM}${default}${C_RESET}]: " >&2
  else
    printf '%s' "$prompt: " >&2
  fi
  IFS= read -r reply || true
  [ -z "$reply" ] && reply="$default"
  printf '%s' "$reply"
}

# Prompt for a secret (no echo). Shows a masked preview of the existing value.
ask_secret() {
  local prompt="$1" current="${2-}" reply preview=""
  if [ -n "$current" ]; then
    local n=${#current}
    if [ "$n" -le 8 ]; then preview="(已有值，回车保留)"
    else preview="(已有 ${current:0:4}…${current: -4}，回车保留)"; fi
  fi
  printf '%s' "$prompt ${C_DIM}${preview}${C_RESET}: " >&2
  IFS= read -rs reply || true
  printf '\n' >&2
  [ -z "$reply" ] && reply="$current"
  printf '%s' "$reply"
}

confirm() {
  local prompt="$1" default="${2:-N}" reply
  local hint="[y/N]"; [ "$default" = "Y" ] && hint="[Y/n]"
  printf '%s' "$prompt $hint: " >&2
  IFS= read -r reply || true
  [ -z "$reply" ] && reply="$default"
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Single-quote a string for safe reuse in shell / config.env.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# --------------------------------------------------------------------------- #
# Claude Code CLI install / update
# --------------------------------------------------------------------------- #
claude_bin() { command -v claude 2>/dev/null || true; }

claude_version() {
  local b; b="$(claude_bin)"
  [ -n "$b" ] && "$b" --version 2>/dev/null | head -n1
}

install_claude_code() {
  hr
  local existing; existing="$(claude_bin)"
  if [ -n "$existing" ]; then
    ok "已检测到 Claude Code: $existing"
    info "当前版本: $(claude_version || echo '未知')"
    confirm "重新安装 / 更新到最新版?" "N" || { pause; return; }
  fi

  echo
  echo "选择安装方式:"
  echo "  1) 官方原生安装脚本 (推荐, 无需 Node)"
  echo "  2) npm 全局安装 (@anthropic-ai/claude-code, 需要 Node >= 18)"
  echo "  3) 仅运行 'claude update' (若已安装)"
  echo "  0) 返回"
  local m; m="$(ask '输入序号' '1')"
  case "$m" in
    1)
      if ! has_cmd curl && ! has_cmd wget; then err "需要 curl 或 wget"; pause; return; fi
      info "正在执行官方安装脚本: https://claude.ai/install.sh"
      if has_cmd curl; then
        curl -fsSL https://claude.ai/install.sh | bash
      else
        wget -qO- https://claude.ai/install.sh | bash
      fi
      ;;
    2)
      if ! has_cmd npm; then err "未找到 npm，请先安装 Node.js (https://nodejs.org)"; pause; return; fi
      info "正在执行: npm install -g @anthropic-ai/claude-code"
      npm install -g @anthropic-ai/claude-code
      ;;
    3)
      [ -z "$existing" ] && { err "尚未安装 Claude Code"; pause; return; }
      "$existing" update || warn "claude update 返回非零"
      ;;
    0|"") return ;;
    *) err "无效选项"; pause; return ;;
  esac

  hash -r 2>/dev/null || true
  local b; b="$(claude_bin)"
  if [ -n "$b" ]; then
    ok "Claude Code 就绪: $b ($("$b" --version 2>/dev/null | head -n1))"
  else
    warn "安装脚本已结束，但当前 shell 未找到 'claude'。"
    warn "通常是 PATH 未刷新 —— 新开一个终端，或执行: source ~/.bashrc (或 ~/.zshrc)"
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) : ;;
      *) warn "提示: 把 \$HOME/.local/bin 加入 PATH" ;;
    esac
  fi
  pause
}

# --------------------------------------------------------------------------- #
# MaaS configuration
# --------------------------------------------------------------------------- #
# In-memory config for the current edit session. No associative arrays so this
# still runs on the stock bash 3.2 shipped with macOS: we stash values in
# variables named CFG_<KEY> and read them back via `${!name}` indirection.
cfg_set() { printf -v "CFG_$1" '%s' "${2-}"; }
cfg_get() { local __n="CFG_$1"; printf '%s' "${!__n-}"; }

load_cfg_into_map() {
  local k
  for k in "${MANAGED_KEYS[@]}"; do cfg_set "$k" "$(config_get "$k")"; done
}

# --------------------------------------------------------------------------- #
# Model list  (~/.config/claude-maas/models.txt, one model name per line)
# --------------------------------------------------------------------------- #
models_all() {
  [ -f "$MODELS_FILE" ] || return 0
  # drop blank lines and comments, keep order, de-dup
  awk 'NF && $0 !~ /^[[:space:]]*#/ && !seen[$0]++' "$MODELS_FILE"
}

models_count() { models_all | awk 'END{print NR+0}'; }

models_has() {
  local want="$1" m
  while IFS= read -r m; do [ "$m" = "$want" ] && return 0; done < <(models_all)
  return 1
}

models_save() {  # stdin -> file (atomic, de-duped, trimmed)
  mkdir -p "$CONFIG_DIR"
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/claude-maas.XXXXXX")"
  awk 'NF && $0 !~ /^[[:space:]]*#/ && !seen[$0]++' > "$tmp"
  mv "$tmp" "$MODELS_FILE"
  chmod 600 "$MODELS_FILE" 2>/dev/null || true
}

models_add() {
  local name; name="$(printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$name" ] && { err "空的模型名"; return 1; }
  if models_has "$name"; then warn "已存在: $name"; return 0; fi
  mkdir -p "$CONFIG_DIR"
  { models_all; printf '%s\n' "$name"; } | models_save
  ok "已添加模型: $name"
}

models_remove() {  # arg: exact name OR 1-based index
  local arg="$1" list target
  list="$(models_all)"
  [ -z "$list" ] && { warn "模型列表为空"; return 0; }
  # resolve arg -> exact model name
  if printf '%s' "$arg" | grep -qE '^[0-9]+$'; then
    target="$(models_nth "$arg")"
  else
    target="$arg"
  fi
  if [ -z "$target" ] || ! models_has "$target"; then warn "未找到: $arg"; return 0; fi
  models_all | grep -Fxv -- "$target" | models_save
  ok "已删除: $target"
  [ "$(effective_or_cfg ANTHROPIC_MODEL)" = "$target" ] && warn "注意: 主模型仍指向已删除的 '$target'，请用 6) 或 'model primary' 重设。"
  [ "$(effective_or_cfg ANTHROPIC_SMALL_FAST_MODEL)" = "$target" ] && warn "注意: 快速模型仍指向已删除的 '$target'。"
}

models_rename() {
  local old="$1" new="$2"
  new="$(printf '%s' "$new" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$new" ] && { err "用法: model edit <旧名> <新名>"; return 1; }
  models_has "$old" || { err "未找到: $old"; return 1; }
  models_all | awk -v o="$old" -v n="$new" '$0==o{print n; next} {print}' | models_save
  ok "已改名: $old -> $new"
  # keep the primary / small pointers in sync with whatever is already stored
  local changed=0
  load_cfg_effective
  [ "$(cfg_get ANTHROPIC_MODEL)" = "$old" ] && { cfg_set ANTHROPIC_MODEL "$new"; changed=1; }
  [ "$(cfg_get ANTHROPIC_SMALL_FAST_MODEL)" = "$old" ] && { cfg_set ANTHROPIC_SMALL_FAST_MODEL "$new"; changed=1; }
  [ "$changed" = "1" ] && persist_current
}

# Print the model list as a numbered menu; marks the current primary / small.
models_print() {
  local list; list="$(models_all)"
  local primary small; primary="$(effective_or_cfg ANTHROPIC_MODEL)"; small="$(effective_or_cfg ANTHROPIC_SMALL_FAST_MODEL)"
  if [ -z "$list" ]; then
    echo "   ${C_DIM}(空 —— 用 'a' 添加，或从预置平台导入)${C_RESET}"
    return
  fi
  local i=0 m tag
  while IFS= read -r m; do
    i=$((i+1)); tag=""
    [ "$m" = "$primary" ] && tag="${tag} ${C_GREEN}[主]${C_RESET}"
    [ "$m" = "$small" ] && tag="${tag} ${C_CYAN}[快速]${C_RESET}"
    printf '   %2d) %s%s\n' "$i" "$m" "$tag"
  done <<EOF
$list
EOF
}

# nth model (1-based) -> stdout
models_nth() { models_all | sed -n "${1}p"; }

# effective value for a key: in-memory edit map, then config.env, then settings.json
effective_or_cfg() {
  local v; v="$(cfg_get "$1")"
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  v="$(config_get "$1")"
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  _settings_read_key "$(json_tool)" "$1"
}

# Fill the CFG_* map with the union of what is currently stored (config.env wins,
# then settings.json). Used by the standalone model manager so re-persisting does
# not wipe keys that live only in one of the two stores.
load_cfg_effective() {
  local k v tool; tool="$(json_tool)"
  for k in "${MANAGED_KEYS[@]}"; do
    v="$(config_get "$k")"
    [ -z "$v" ] && v="$(_settings_read_key "$tool" "$k")"
    cfg_set "$k" "$v"
  done
}

# Write the current CFG_* map back to whichever stores already exist.
persist_current() {
  local did=0 tool; tool="$(json_tool)"
  if [ -f "$CLAUDE_SETTINGS_FILE" ] && \
     [ -n "$(_settings_read_key "$tool" ANTHROPIC_BASE_URL)$(_settings_read_key "$tool" ANTHROPIC_MODEL)$(_settings_read_key "$tool" ANTHROPIC_SMALL_FAST_MODEL)" ]; then
    apply_settings_json && did=1
  fi
  if [ -f "$CONFIG_FILE" ]; then
    write_config_env && did=1
  fi
  [ "$did" = "0" ] && { warn "尚无已保存的写入位置；请先运行「配置 MaaS 连接」保存一次。"; return 1; }
  return 0
}

# Point ANTHROPIC_MODEL / ANTHROPIC_SMALL_FAST_MODEL at a model name and persist.
models_set_pointer() {
  local key="$1" name="$2"
  load_cfg_effective
  cfg_set "$key" "$name"
  if persist_current; then
    if [ -z "$name" ]; then ok "已清空 $key"; else ok "$key = $name"; fi
  else
    warn "$key 暂存为 '$name'，但尚未落盘。请先「配置 MaaS 连接」。"
  fi
}

# Look up a preset row by key -> "display|base_url|help_url" on stdout
preset_row() {
  local key="$1" row
  for row in "${PRESETS[@]}"; do
    case "$row" in "$key|"*) printf '%s' "${row#*|}"; return 0 ;; esac
  done
  return 1
}

# 1-based position of a model name in the list (0 if absent)
models_index_of() {
  local want="$1" i=0 m
  while IFS= read -r m; do
    i=$((i+1)); [ "$m" = "$want" ] && { printf '%s' "$i"; return 0; }
  done < <(models_all)
  printf '0'
}

# Interactive model chooser. Prompts on stderr, prints the chosen name on stdout.
# Picking a number selects from the list; 'm' or a free string adds a new one; 0 clears.
pick_model() {
  local label="$1" current="${2-}" list sel manual picked
  list="$(models_all)"
  {
    echo
    echo "$label"
    if [ -n "$list" ]; then
      local i=0 m
      while IFS= read -r m; do
        i=$((i+1))
        if [ "$m" = "$current" ]; then printf '  %2d) %s  %s<- 当前%s\n' "$i" "$m" "$C_DIM" "$C_RESET"
        else printf '  %2d) %s\n' "$i" "$m"; fi
      done <<EOF
$list
EOF
    else
      echo "  ${C_DIM}(模型列表为空 —— 直接输入模型名即可加入列表)${C_RESET}"
    fi
    echo "   m) 手动输入新模型名 (并加入列表)"
    echo "   0) 留空 (用 Claude Code 默认)"
  } >&2
  local def; def="$(models_index_of "$current")"; [ "$def" = "0" ] && def="0"
  sel="$(ask '选择' "$def")"
  case "$sel" in
    0|"") printf '' ;;
    m|M)
      manual="$(ask '模型名')"
      [ -n "$manual" ] && models_add "$manual" >&2
      printf '%s' "$manual"
      ;;
    *)
      if printf '%s' "$sel" | grep -qE '^[0-9]+$'; then
        picked="$(models_nth "$sel")"
        if [ -n "$picked" ]; then printf '%s' "$picked"; else warn "序号超出范围，按留空处理"; printf ''; fi
      else
        models_add "$sel" >&2
        printf '%s' "$sel"
      fi
      ;;
  esac
}

# --------------------------------------------------------------------------- #
# Model list manager (menu + `claude-maas model ...`)
# --------------------------------------------------------------------------- #
manage_models() {
  while true; do
    hr
    echo "${C_BOLD}模型列表${C_RESET}   ${C_DIM}($MODELS_FILE)${C_RESET}"
    models_print
    echo
    echo "  a) 添加    d) 删除(名称或序号)    e) 改名    p) 设为主模型    s) 设为快速模型"
    echo "  c) 清空    i) 从预置平台导入示例    0) 返回"
    hr
    local op; op="$(ask '操作' '')"
    case "$op" in
      a) local n; n="$(ask '新模型名')"; [ -n "$n" ] && models_add "$n" ;;
      d) local n; n="$(ask '要删除的模型名或序号')"; [ -n "$n" ] && models_remove "$n" ;;
      e) local o x; o="$(ask '旧名 (或序号)')"; [ "$o" -gt 0 ] 2>/dev/null && o="$(models_nth "$o")"
         [ -n "$o" ] && { x="$(ask "新名 (原: $o)")"; models_rename "$o" "$x"; } ;;
      p) local n; n="$(pick_model '设为主模型 ANTHROPIC_MODEL' "$(effective_or_cfg ANTHROPIC_MODEL)")"; models_set_pointer ANTHROPIC_MODEL "$n" ;;
      s) local n; n="$(pick_model '设为快速模型 ANTHROPIC_SMALL_FAST_MODEL' "$(effective_or_cfg ANTHROPIC_SMALL_FAST_MODEL)")"; models_set_pointer ANTHROPIC_SMALL_FAST_MODEL "$n" ;;
      c) confirm "清空整个模型列表?" "N" && { : | models_save; ok "已清空"; } ;;
      i)
        echo "预置平台:"
        local i=0 row
        for row in "${PRESETS[@]}"; do
          i=$((i+1)); printf '  %d) %s\n' "$i" "$(printf '%s' "$row" | awk -F'|' '{print $2}')"
        done
        local s; s="$(ask '选择平台序号' '')"
        row=""
        printf '%s' "$s" | grep -qE '^[1-9][0-9]*$' && [ "$s" -le "${#PRESETS[@]}" ] && \
          row="$(printf '%s\n' "${PRESETS[@]}" | sed -n "${s}p")"
        if [ -n "$row" ]; then
          local hlp; hlp="$(printf '%s' "$row" | awk -F'|' '{print $4}')"
          warn "本工具不内置各家的具体模型名（更新频繁）。"
          [ "$hlp" != "-" ] && [ -n "$hlp" ] && info "请到该平台文档查模型名: $hlp"
          local mm; mm="$(ask '现在手动输入一个该平台模型名 (可留空)')"
          [ -n "$mm" ] && models_add "$mm"
        fi
        ;;
      0|q|Q|"") return ;;
      *) err "无效操作" ;;
    esac
  done
}

# `claude-maas model[s] ...`
models_cli() {
  local sub="${1-}"; shift 2>/dev/null || true
  case "$sub" in
    ""|list|ls)     models_all ;;
    add)            [ -n "${1-}" ] || { err "用法: claude-maas model add <名称> [名称...]"; return 2; }
                    local m; for m in "$@"; do models_add "$m"; done ;;
    rm|remove|del)  [ -n "${1-}" ] || { err "用法: claude-maas model rm <名称|序号>"; return 2; }
                    local m; for m in "$@"; do models_remove "$m"; done ;;
    edit|rename|mv) models_rename "${1-}" "${2-}" ;;
    primary|main)   [ -n "${1-}" ] || { err "用法: claude-maas model primary <名称>"; return 2; }
                    models_set_pointer ANTHROPIC_MODEL "$1" ;;
    small|fast)     [ -n "${1-}" ] || { err "用法: claude-maas model small <名称>"; return 2; }
                    models_set_pointer ANTHROPIC_SMALL_FAST_MODEL "$1" ;;
    edit-menu|menu|"-") manage_models ;;
    *) err "未知子命令: $sub"; echo "可用: list | add | rm | edit | primary | small | menu"; return 2 ;;
  esac
}

configure_maas() {
  hr
  echo "${C_BOLD}配置 MaaS 连接${C_RESET}"
  echo "${C_DIM}留空表示不设置 / 清除该项。Token 输入时不回显。${C_RESET}"
  echo

  load_cfg_effective

  local base token apikey model small
  local cur_base; cur_base="$(cfg_get ANTHROPIC_BASE_URL)"

  # --- 1. 选择 MaaS 平台 ------------------------------------------------------
  echo "选择 MaaS 平台 (预置地址仅为便捷，以各家官方文档为准):"
  local i=0 row key disp url help
  for row in "${PRESETS[@]}"; do
    i=$((i+1))
    key="${row%%|*}"; disp="$(printf '%s' "$row" | awk -F'|' '{print $2}')"
    url="$(printf '%s' "$row" | awk -F'|' '{print $3}')"
    if [ "$url" = "-" ]; then printf '  %d) %s\n' "$i" "$disp"
    else printf '  %d) %-26s %s%s%s\n' "$i" "$disp" "$C_DIM" "$url" "$C_RESET"; fi
  done
  local pdef=1 j=0
  for row in "${PRESETS[@]}"; do
    j=$((j+1)); url="$(printf '%s' "$row" | awk -F'|' '{print $3}')"
    [ -n "$cur_base" ] && [ "$url" = "$cur_base" ] && pdef=$j
  done
  local psel; psel="$(ask '输入序号' "$pdef")"
  if ! printf '%s' "$psel" | grep -qE '^[1-9][0-9]*$' || [ "$psel" -gt "${#PRESETS[@]}" ]; then
    err "无效选项"; pause; return
  fi
  row="$(printf '%s\n' "${PRESETS[@]}" | sed -n "${psel}p")"
  [ -z "$row" ] && { err "无效选项"; pause; return; }
  key="${row%%|*}"
  url="$(printf '%s' "$row" | awk -F'|' '{print $3}')"
  help="$(printf '%s' "$row" | awk -F'|' '{print $4}')"

  if [ "$key" = "custom" ] || [ "$url" = "-" ]; then
    base="$(ask 'ANTHROPIC_BASE_URL  (形如 https://your-maas.example.com/api)' "$cur_base")"
  else
    base="$(ask "ANTHROPIC_BASE_URL  (回车用预置值)" "${url}")"
    [ "$help" != "-" ] && [ -n "$help" ] && info "获取 API Key / 文档: $help"
  fi
  base="${base%/}"

  # --- 2. 鉴权 --------------------------------------------------------------
  echo
  echo "鉴权方式 (二选一，取决于你的 MaaS 平台):"
  echo "  1) Bearer Token  -> 写入 ANTHROPIC_AUTH_TOKEN (最常见)"
  echo "  2) API Key       -> 写入 ANTHROPIC_API_KEY (x-api-key 头)"
  local am; am="$(ask '输入序号' '1')"
  if [ "$am" = "2" ]; then
    apikey="$(ask_secret 'ANTHROPIC_API_KEY' "$(cfg_get ANTHROPIC_API_KEY)")"
    token=""
  else
    token="$(ask_secret 'ANTHROPIC_AUTH_TOKEN' "$(cfg_get ANTHROPIC_AUTH_TOKEN)")"
    apikey=""
  fi

  # --- 3. 选择模型 (来自模型列表, 见菜单 6) --------------------------------
  echo
  echo "${C_DIM}模型名各家不同。下面从你的「模型列表」里选；留空则用 Claude Code 默认值。${C_RESET}"
  model="$(pick_model '主模型 ANTHROPIC_MODEL' "$(cfg_get ANTHROPIC_MODEL)")"
  small="$(pick_model '快速模型 ANTHROPIC_SMALL_FAST_MODEL' "$(cfg_get ANTHROPIC_SMALL_FAST_MODEL)")"

  cfg_set ANTHROPIC_BASE_URL "$base"
  cfg_set ANTHROPIC_AUTH_TOKEN "$token"
  cfg_set ANTHROPIC_API_KEY "$apikey"
  cfg_set ANTHROPIC_MODEL "$model"
  cfg_set ANTHROPIC_SMALL_FAST_MODEL "$small"

  echo
  hr
  echo "写入方式:"
  echo "  1) ${C_BOLD}Claude Code settings.json${C_RESET}  (~/.claude/settings.json 的 env 块)"
  echo "     跨平台一致、只影响 Claude Code、不改动 shell 配置 —— ${C_GREEN}推荐${C_RESET}"
  echo "  2) 系统环境变量 (shell 启动文件)"
  echo "     写入 $CONFIG_FILE 并在 ~/.bashrc / ~/.zshrc / ~/.profile / fish 注入受管块"
  echo "     对所有读取 ANTHROPIC_* 的工具生效；需要重开终端"
  echo "  3) 两者都写"
  echo "  0) 取消"
  local w; w="$(ask '输入序号' '1')"

  case "$w" in
    1) apply_settings_json ;;
    2) apply_env_files ;;
    3) apply_settings_json; apply_env_files ;;
    0|"") warn "已取消，未写入任何配置"; pause; return ;;
    *) err "无效选项"; pause; return ;;
  esac

  echo
  ok "配置完成。"
  echo "${C_DIM}重开一个终端后运行 'claude' 即可使用新配置。${C_RESET}"
  pause
}

# --- writer: config.env + shell rc managed blocks --------------------------- #
write_config_env() {
  mkdir -p "$CONFIG_DIR"
  umask 077
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/claude-maas.XXXXXX")"
  {
    echo "# Managed by claude-maas — do not edit by hand; run: claude-maas"
    echo "# $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local k v
    for k in "${MANAGED_KEYS[@]}"; do
      v="$(cfg_get "$k")"
      [ -n "$v" ] && printf '%s=%s\n' "$k" "$(shq "$v")"
    done
  } > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  ok "已写入 $CONFIG_FILE"
}

posix_block() {
  cat <<EOF
$MARK_BEGIN
# Managed by claude-maas. Edit via: claude-maas
if [ -f "$CONFIG_FILE" ]; then
  set -a
  . "$CONFIG_FILE"
  set +a
fi
$MARK_END
EOF
}

fish_block() {
  cat <<EOF
$MARK_BEGIN
# Managed by claude-maas. Edit via: claude-maas
if test -f "$CONFIG_FILE"
    for __cm_line in (string match -rv '^\s*#|^\s*\$' < "$CONFIG_FILE")
        set --local __cm_kv (string split -m1 '=' -- \$__cm_line)
        set -gx \$__cm_kv[1] (string trim --chars=\\' -- \$__cm_kv[2])
    end
    set -e __cm_line __cm_kv
end
$MARK_END
EOF
}

# Remove an existing managed block (between markers) from a file, in place.
strip_managed_block() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep -q "$MARK_BEGIN" "$file" 2>/dev/null || return 0
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/claude-maas.XXXXXX")"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    skip != 1 {print}
  ' "$file" > "$tmp"
  # drop trailing blank lines that we may have introduced
  awk 'NF{p=NR} {a[NR]=$0} END{for(i=1;i<=p;i++) print a[i]}' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

inject_block() {
  local file="$1" kind="$2"   # kind: posix | fish
  local dir; dir="$(dirname "$file")"
  mkdir -p "$dir"
  [ -f "$file" ] || : > "$file"
  if grep -q "$MARK_BEGIN" "$file" 2>/dev/null; then
    cp "$file" "$file.claude-maas.bak"
    strip_managed_block "$file"
  else
    cp "$file" "$file.claude-maas.bak" 2>/dev/null || true
  fi
  {
    printf '\n'
    if [ "$kind" = "fish" ]; then fish_block; else posix_block; fi
  } >> "$file"
  ok "已更新 $file  ${C_DIM}(备份: $(basename "$file").claude-maas.bak)${C_RESET}"
}

apply_env_files() {
  write_config_env

  local touched=0
  # POSIX-ish shells: modify the files that exist, always ensure ~/.profile.
  local f
  for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$f" ] || { [ "$f" = "$HOME/.profile" ]; }; then
      inject_block "$f" posix
      touched=1
    fi
  done
  # zsh: ~/.zshrc may not exist yet but zsh is the login shell on macOS
  if [ ! -f "$HOME/.zshrc" ] && { [ "$(basename "${SHELL:-}")" = "zsh" ] || [ "$(detect_os)" = "macos" ]; }; then
    inject_block "$HOME/.zshrc" posix
  fi
  # fish
  if [ -d "$HOME/.config/fish" ] || [ "$(basename "${SHELL:-}")" = "fish" ]; then
    inject_block "$HOME/.config/fish/config.fish" fish
  fi

  [ "$touched" = "1" ] && ok "shell 启动文件已注入受管块。"
  warn "当前终端不会自动生效；请重开终端，或手动: set -a && . \"$CONFIG_FILE\" && set +a"
}

# --- writer: ~/.claude/settings.json env block ---------------------------- #
# Pick a JSON tool that ACTUALLY works (Windows ships a python3 "app execution
# alias" stub that is on PATH but does nothing). Result is cached per run.
JSON_TOOL_CACHE=""
json_tool() {
  [ -n "$JSON_TOOL_CACHE" ] && { printf '%s' "$JSON_TOOL_CACHE"; return; }
  local t=none
  if has_cmd jq && printf '{}' | jq -e . >/dev/null 2>&1; then t=jq
  elif has_cmd node && node -e 'JSON.parse("{}")' >/dev/null 2>&1; then t=node
  elif has_cmd python3 && python3 -c 'import json' >/dev/null 2>&1; then t=python3
  elif has_cmd python && python -c 'import json' >/dev/null 2>&1; then t=python
  fi
  JSON_TOOL_CACHE="$t"
  printf '%s' "$t"
}

apply_settings_json() {
  local tool; tool="$(json_tool)"
  if [ "$tool" = "none" ]; then
    err "settings.json 方式需要 jq / python3 / node 之一，均未找到。"
    warn "改用「系统环境变量」方式，或安装 jq 后重试。"
    return 1
  fi

  mkdir -p "$CLAUDE_SETTINGS_DIR"

  # Protect a pre-existing, non-empty settings.json: if it does not parse, stop
  # rather than risk clobbering real settings. A missing / empty file is fine —
  # we just start from {}.
  if [ -s "$CLAUDE_SETTINGS_FILE" ] && grep -q '[^[:space:]]' "$CLAUDE_SETTINGS_FILE" 2>/dev/null; then
    if ! _json_valid "$tool" "$CLAUDE_SETTINGS_FILE"; then
      err "$CLAUDE_SETTINGS_FILE 不是合法 JSON，已跳过以免损坏。请手动修复后重试。"
      return 1
    fi
    cp "$CLAUDE_SETTINGS_FILE" "$CLAUDE_SETTINGS_FILE.claude-maas.bak"
  else
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
  fi

  # Build a KEY=VALUE list (only non-empty) + list of keys to delete (empty).
  local set_pairs=() del_keys=() k v
  for k in "${MANAGED_KEYS[@]}"; do
    v="$(cfg_get "$k")"
    if [ -n "$v" ]; then set_pairs+=("$k=$v"); else del_keys+=("$k"); fi
  done

  case "$tool" in
    jq)     _settings_jq     "${set_pairs[@]}" "--" "${del_keys[@]}" ;;
    node)   _settings_node   "${set_pairs[@]}" "--" "${del_keys[@]}" ;;
    *)      _settings_python "$tool" "${set_pairs[@]}" "--" "${del_keys[@]}" ;;
  esac || { err "写入 settings.json 失败，已保留备份。"; return 1; }

  chmod 600 "$CLAUDE_SETTINGS_FILE" 2>/dev/null || true
  ok "已更新 $CLAUDE_SETTINGS_FILE  ${C_DIM}(备份: settings.json.claude-maas.bak)${C_RESET}"
}

_json_valid() {
  local tool="$1" file="$2"
  case "$tool" in
    jq)   jq -e . "$file" >/dev/null 2>&1 ;;
    node) node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$file" >/dev/null 2>&1 ;;
    *)    "$tool" -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" >/dev/null 2>&1 ;;
  esac
}

_settings_jq() {
  local args=("$@") mode="set" k v a
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/claude-maas.XXXXXX")"
  local filter='.env = (.env // {})'
  local jqargs=()
  local i=0
  for a in "${args[@]}"; do
    if [ "$a" = "--" ]; then mode="del"; continue; fi
    if [ "$mode" = "set" ]; then
      k="${a%%=*}"; v="${a#*=}"
      jqargs+=(--arg "k$i" "$k" --arg "v$i" "$v")
      filter="$filter | .env[\$k$i] = \$v$i"
    else
      jqargs+=(--arg "d$i" "$a")
      filter="$filter | del(.env[\$d$i])"
    fi
    i=$((i+1))
  done
  filter="$filter | (if (.env | length) == 0 then del(.env) else . end)"
  jq "${jqargs[@]}" "$filter" "$CLAUDE_SETTINGS_FILE" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS_FILE"
}

_settings_python() {
  local py="$1"; shift
  "$py" - "$CLAUDE_SETTINGS_FILE" "$@" <<'PYEOF'
import json, sys
path = sys.argv[1]
rest = sys.argv[2:]
sep = rest.index('--') if '--' in rest else len(rest)
sets = rest[:sep]
dels = rest[sep+1:] if '--' in rest else []
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
if not isinstance(data, dict):
    print('settings.json 顶层不是对象', file=sys.stderr); sys.exit(1)
env = data.get('env')
if not isinstance(env, dict):
    env = {}
for pair in sets:
    k, _, v = pair.partition('=')
    env[k] = v
for k in dels:
    env.pop(k, None)
if env:
    data['env'] = env
else:
    data.pop('env', None)
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
PYEOF
}

_settings_node() {
  node - "$CLAUDE_SETTINGS_FILE" "$@" <<'NODEEOF'
const fs = require('fs');
const path = process.argv[2];
const rest = process.argv.slice(3);
const sep = rest.indexOf('--');
const sets = sep === -1 ? rest : rest.slice(0, sep);
const dels = sep === -1 ? [] : rest.slice(sep + 1);
const data = JSON.parse(fs.readFileSync(path, 'utf8'));
if (typeof data !== 'object' || data === null || Array.isArray(data)) {
  console.error('settings.json 顶层不是对象'); process.exit(1);
}
let env = (data.env && typeof data.env === 'object' && !Array.isArray(data.env)) ? data.env : {};
for (const pair of sets) {
  const i = pair.indexOf('=');
  env[pair.slice(0, i)] = pair.slice(i + 1);
}
for (const k of dels) delete env[k];
if (Object.keys(env).length) data.env = env; else delete data.env;
fs.writeFileSync(path, JSON.stringify(data, null, 2) + '\n');
NODEEOF
}

# --------------------------------------------------------------------------- #
# Show current config
# --------------------------------------------------------------------------- #
mask() {
  local v="$1"
  [ -z "$v" ] && { printf '%s' "${C_DIM}(未设置)${C_RESET}"; return; }
  local n=${#v}
  if [ "$n" -le 10 ]; then printf '%s' "***"; else printf '%s' "${v:0:4}…${v: -4}"; fi
}

show_config() {
  hr
  echo "${C_BOLD}当前配置${C_RESET}"
  echo

  echo "${C_CYAN}1) Claude Code settings.json${C_RESET}  ($CLAUDE_SETTINGS_FILE)"
  if [ -f "$CLAUDE_SETTINGS_FILE" ]; then
    local tool; tool="$(json_tool)"
    local k v
    for k in "${MANAGED_KEYS[@]}"; do
      v="$(_settings_read_key "$tool" "$k")"
      if [ -n "$v" ]; then
        case "$k" in *TOKEN|*API_KEY) v="$(mask "$v")";; esac
        printf '   %-28s = %s\n' "$k" "$v"
      fi
    done
  else
    echo "   ${C_DIM}(文件不存在)${C_RESET}"
  fi

  echo
  echo "${C_CYAN}2) 受管环境变量文件${C_RESET}  ($CONFIG_FILE)"
  if [ -f "$CONFIG_FILE" ]; then
    local k v
    for k in "${MANAGED_KEYS[@]}"; do
      v="$(config_get "$k")"
      if [ -n "$v" ]; then
        case "$k" in *TOKEN|*API_KEY) v="$(mask "$v")";; esac
        printf '   %-28s = %s\n' "$k" "$v"
      fi
    done
    echo "   ${C_DIM}注入的 shell 文件:${C_RESET}"
    local f
    for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.config/fish/config.fish"; do
      [ -f "$f" ] && grep -q "$MARK_BEGIN" "$f" 2>/dev/null && echo "     - $f"
    done
  else
    echo "   ${C_DIM}(文件不存在)${C_RESET}"
  fi

  echo
  echo "${C_CYAN}3) 当前 shell 里已生效的值${C_RESET} (本终端)"
  local k any=0
  for k in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL; do
    if [ -n "${!k-}" ]; then
      any=1
      local v="${!k}"
      case "$k" in *TOKEN|*API_KEY) v="$(mask "$v")";; esac
      printf '   %-28s = %s\n' "$k" "$v"
    fi
  done
  [ "$any" = "0" ] && echo "   ${C_DIM}(无 —— 需重开终端，或本终端未走受管配置)${C_RESET}"

  echo
  echo "${C_CYAN}4) 模型列表${C_RESET}  ($MODELS_FILE)"
  models_print

  echo
  local b; b="$(claude_bin)"
  if [ -n "$b" ]; then
    echo "${C_CYAN}Claude Code${C_RESET}: $b  ($("$b" --version 2>/dev/null | head -n1))"
  else
    echo "${C_CYAN}Claude Code${C_RESET}: ${C_DIM}未安装 / 不在 PATH${C_RESET}"
  fi
  pause
}

_settings_read_key() {
  local tool="$1" key="$2"
  [ -f "$CLAUDE_SETTINGS_FILE" ] || return 0
  case "$tool" in
    jq)   jq -r --arg k "$key" '.env[$k] // empty' "$CLAUDE_SETTINGS_FILE" 2>/dev/null ;;
    node) node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(((d.env||{})[process.argv[2]])||"")' "$CLAUDE_SETTINGS_FILE" "$key" 2>/dev/null ;;
    python3|python) "$tool" -c 'import json,sys;d=json.load(open(sys.argv[1]));print((d.get("env") or {}).get(sys.argv[2],""))' "$CLAUDE_SETTINGS_FILE" "$key" 2>/dev/null ;;
    *) grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CLAUDE_SETTINGS_FILE" 2>/dev/null | head -n1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/' ;;
  esac
}

# --------------------------------------------------------------------------- #
# Test connection
# --------------------------------------------------------------------------- #
resolve_effective() {
  # Effective value: current shell env wins, then settings.json, then config.env.
  local key="$1"
  if [ -n "${!key-}" ]; then printf '%s' "${!key}"; return; fi
  local v; v="$(_settings_read_key "$(json_tool)" "$key")"
  [ -n "$v" ] && { printf '%s' "$v"; return; }
  config_get "$key"
}

test_connection() {
  hr
  if ! has_cmd curl; then err "需要 curl"; pause; return; fi

  local base token apikey model
  base="$(resolve_effective ANTHROPIC_BASE_URL)"
  token="$(resolve_effective ANTHROPIC_AUTH_TOKEN)"
  apikey="$(resolve_effective ANTHROPIC_API_KEY)"
  model="$(resolve_effective ANTHROPIC_SMALL_FAST_MODEL)"
  [ -z "$model" ] && model="$(resolve_effective ANTHROPIC_MODEL)"
  [ -z "$model" ] && model="claude-3-5-haiku-20241022"

  if [ -z "$base" ]; then err "未找到 ANTHROPIC_BASE_URL，请先运行「配置 MaaS 连接」"; pause; return; fi

  info "Base URL : $base"
  info "Model    : $model"
  info "Auth     : $( [ -n "$token" ] && echo 'Bearer ANTHROPIC_AUTH_TOKEN' || { [ -n "$apikey" ] && echo 'x-api-key ANTHROPIC_API_KEY' || echo '(无, 可能失败)'; } )"
  echo

  local url="$base/v1/messages"
  local body; body='{"model":"'"$model"'","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}'
  local hdr=(-H "content-type: application/json" -H "anthropic-version: 2023-06-01")
  [ -n "$token" ]  && hdr+=(-H "authorization: Bearer $token")
  [ -n "$apikey" ] && hdr+=(-H "x-api-key: $apikey")

  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/claude-maas.XXXXXX")"
  local code
  code="$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 30 -X POST "$url" "${hdr[@]}" -d "$body" 2>"$tmp.err")"
  local rc=$?

  echo "POST $url"
  if [ $rc -ne 0 ]; then
    err "curl 失败 (exit $rc): $(head -c 300 "$tmp.err")"
  else
    case "$code" in
      200|201) ok "HTTP $code —— 连接与鉴权正常 ✅" ;;
      400) warn "HTTP 400 —— 已连通且鉴权可能通过；多为模型名不被接受。响应:"; head -c 500 "$tmp"; echo ;;
      401|403) err "HTTP $code —— 鉴权失败，请检查 Token / API Key。响应:"; head -c 400 "$tmp"; echo ;;
      404) err "HTTP 404 —— 路径不对，检查 BASE_URL 是否要去掉/加上 /v1 之类的前缀。响应:"; head -c 300 "$tmp"; echo ;;
      000) err "HTTP 000 —— 无法建立连接 (DNS / 网络 / TLS)" ;;
      *) warn "HTTP $code —— 响应:"; head -c 500 "$tmp"; echo ;;
    esac
  fi
  rm -f "$tmp" "$tmp.err"
  pause
}

# --------------------------------------------------------------------------- #
# Run claude
# --------------------------------------------------------------------------- #
run_claude() {
  hr
  local b; b="$(claude_bin)"
  [ -z "$b" ] && { err "未安装 Claude Code，请先选 1"; pause; return; }
  # Load managed env for this invocation so it works even without reopening a shell.
  if [ -f "$CONFIG_FILE" ]; then set -a; . "$CONFIG_FILE"; set +a; fi
  info "启动: $b"
  "$b" || true
  pause
}

# --------------------------------------------------------------------------- #
# Self install / uninstall
# --------------------------------------------------------------------------- #
install_self() {
  local src="${BASH_SOURCE[0]}"
  # When run via process substitution BASH_SOURCE is /dev/fd/xx — re-fetch from repo.
  mkdir -p "$(dirname "$SELF_INSTALL_PATH")"
  if [ -f "$src" ] && [ "$src" -ef "$SELF_INSTALL_PATH" ]; then
    ok "管理命令已是最新 (从自身运行): $SELF_INSTALL_PATH"
    chmod +x "$SELF_INSTALL_PATH" 2>/dev/null || true
    return 0
  fi
  if [ -f "$src" ] && [ -r "$src" ] && [ "${src#/dev/fd}" = "$src" ] && [ "${src#/proc/self}" = "$src" ]; then
    cp "$src" "$SELF_INSTALL_PATH"
  else
    local raw="https://raw.githubusercontent.com/rynnwang/install-claude-cli-with-maas/main/claude-maas.sh"
    info "从仓库获取脚本: $raw"
    if has_cmd curl; then curl -fsSL "$raw" -o "$SELF_INSTALL_PATH"
    elif has_cmd wget; then wget -qO "$SELF_INSTALL_PATH" "$raw"
    else err "需要 curl 或 wget 来安装管理命令"; return 1; fi
  fi
  chmod +x "$SELF_INSTALL_PATH"
  ok "已安装管理命令: $SELF_INSTALL_PATH"

  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ok "以后直接运行: ${C_BOLD}claude-maas${C_RESET}" ;;
    *)
      warn "\$HOME/.local/bin 不在 PATH 中。已尝试为你加入 shell 启动文件。"
      local line='export PATH="$HOME/.local/bin:$PATH"'
      local f
      for f in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        [ -f "$f" ] || continue
        grep -qF "$line" "$f" 2>/dev/null || printf '\n%s\n' "$line" >> "$f"
      done
      warn "重开终端后可用 'claude-maas'；本次可用完整路径: $SELF_INSTALL_PATH"
      ;;
  esac
}

uninstall_all() {
  hr
  warn "即将移除 claude-maas 的配置与管理命令。"
  confirm "继续?" "N" || { pause; return; }

  local f
  for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.config/fish/config.fish"; do
    if [ -f "$f" ] && grep -q "$MARK_BEGIN" "$f" 2>/dev/null; then
      cp "$f" "$f.claude-maas.bak"
      strip_managed_block "$f"
      ok "已从 $f 移除受管块 (备份 .claude-maas.bak)"
    fi
  done

  if confirm "删除 settings.json 中的受管 env 键?" "Y"; then
    local k; for k in "${MANAGED_KEYS[@]}"; do cfg_set "$k" ""; done
    apply_settings_json || true
  fi

  if confirm "删除配置目录 $CONFIG_DIR ?" "Y"; then
    rm -rf "$CONFIG_DIR"; ok "已删除 $CONFIG_DIR"
  fi

  if [ -f "$SELF_INSTALL_PATH" ] && confirm "删除管理命令 $SELF_INSTALL_PATH ?" "Y"; then
    rm -f "$SELF_INSTALL_PATH"; ok "已删除"
  fi

  local b; b="$(claude_bin)"
  if [ -n "$b" ] && confirm "同时卸载 Claude Code CLI 本体? ($b)" "N"; then
    if has_cmd claude; then claude uninstall 2>/dev/null || warn "claude uninstall 不可用，请按安装方式手动卸载"; fi
  fi

  ok "卸载完成。可能需要重开终端。"
  pause
}

# --------------------------------------------------------------------------- #
# Menu
# --------------------------------------------------------------------------- #
banner() {
  clear 2>/dev/null || true
  echo "${C_BOLD}${C_BLUE}"
  echo "   claude-maas  ·  Claude Code CLI + MaaS 一键安装 / 管理"
  echo "${C_RESET}${C_DIM}  v$VERSION   $(detect_os)   $(uname -m)${C_RESET}"
  hr
  local b; b="$(claude_bin)"
  local cs="${C_RED}未安装${C_RESET}"; [ -n "$b" ] && cs="${C_GREEN}$("$b" --version 2>/dev/null | head -n1)${C_RESET}"
  local conf="${C_RED}未配置${C_RESET}"
  { [ -f "$CONFIG_FILE" ] || [ -n "$(_settings_read_key "$(json_tool)" ANTHROPIC_BASE_URL)" ]; } && conf="${C_GREEN}已配置${C_RESET}"
  local self="${C_DIM}(本次为一次性运行)${C_RESET}"; [ -f "$SELF_INSTALL_PATH" ] && self="${C_GREEN}claude-maas 命令已安装${C_RESET}"
  local nm; nm="$(models_count 2>/dev/null || echo 0)"
  printf '  Claude Code : %s\n' "$cs"
  printf '  MaaS 配置   : %s\n' "$conf"
  printf '  模型列表    : %s 个\n' "$nm"
  printf '  管理命令    : %s\n' "$self"
  hr
}

menu() {
  while true; do
    banner
    cat <<EOF
  ${C_BOLD}1${C_RESET})  安装 / 更新 Claude Code CLI
  ${C_BOLD}2${C_RESET})  配置 MaaS 连接 (平台 / Token / 模型)
  ${C_BOLD}3${C_RESET})  查看当前配置
  ${C_BOLD}4${C_RESET})  测试连接
  ${C_BOLD}5${C_RESET})  启动 Claude Code
  ${C_BOLD}6${C_RESET})  管理模型列表 (增 / 删 / 改 / 设主/快速)
  ${C_BOLD}8${C_RESET})  安装 / 更新 "claude-maas" 管理命令
  ${C_BOLD}9${C_RESET})  卸载 (配置 / 管理命令 / 可选卸载 CLI)
  ${C_BOLD}0${C_RESET})  退出
EOF
    hr
    local choice
    printf '%s' "请选择: "
    if ! IFS= read -r choice; then
      echo
      err "标准输入已结束 (EOF)。若你是用 'curl | bash' 运行的，请改用: bash <(curl -fsSL <url>)"
      exit 1
    fi
    case "$choice" in
      1) install_claude_code ;;
      2) configure_maas ;;
      3) show_config ;;
      4) test_connection ;;
      5) run_claude ;;
      6) manage_models ;;
      8) install_self; pause ;;
      9) uninstall_all ;;
      0|q|Q) echo "bye."; exit 0 ;;
      "") : ;;
      *) err "无效选项: $choice"; sleep 1 ;;
    esac
  done
}

# --------------------------------------------------------------------------- #
# CLI entrypoint
# --------------------------------------------------------------------------- #
usage() {
  cat <<EOF
claude-maas v$VERSION — Claude Code CLI + MaaS 一键安装 / 管理

用法:
  claude-maas                 打开交互菜单
  claude-maas install         安装/更新 Claude Code CLI (非交互提示)
  claude-maas config          配置 MaaS 连接
  claude-maas show            打印当前配置
  claude-maas test            测试到 MaaS 的连接
  claude-maas run             加载受管环境并启动 claude
  claude-maas self-install    把本脚本安装为 'claude-maas' 命令
  claude-maas uninstall       移除配置 / 管理命令
  claude-maas help            显示本帮助

模型列表:
  claude-maas models                     列出所有模型
  claude-maas model add <名称> [名称...]  添加
  claude-maas model rm  <名称|序号>       删除
  claude-maas model edit <旧名> <新名>    改名
  claude-maas model primary <名称>       设为主模型 (ANTHROPIC_MODEL)
  claude-maas model small   <名称>       设为快速模型 (ANTHROPIC_SMALL_FAST_MODEL)
  claude-maas model menu                 打开模型列表管理菜单
EOF
}

main() {
  local cmd="${1-}"; [ "$#" -gt 0 ] && shift
  case "$cmd" in
    ""|menu)        menu ;;
    install)        install_claude_code ;;
    config|configure) configure_maas ;;
    show|status)    show_config ;;
    test)           test_connection ;;
    run)            run_claude ;;
    models)         models_cli list ;;
    model)          models_cli "$@" ;;
    self-install)   install_self ;;
    uninstall|remove) uninstall_all ;;
    -h|--help|help) usage ;;
    -v|--version)   echo "$VERSION" ;;
    *) err "未知命令: $cmd"; echo; usage; exit 2 ;;
  esac
}

# Offer to install the manager command on the very first curl|bash run.
if [ -z "${1-}" ] && [ ! -f "$SELF_INSTALL_PATH" ] && [ -t 0 ]; then
  banner
  echo "首次运行。安装 'claude-maas' 管理命令后，之后可随时用它重开此菜单。"
  if confirm "现在安装管理命令?" "Y"; then install_self; echo; sleep 1; fi
fi

main "$@"
