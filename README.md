# install-claude-cli-with-maas

一键在本地安装 **Claude Code CLI**，并把它对接到你的 **MaaS**（Anthropic 兼容的模型网关 / 中转）平台。

交互逻辑参考了 [fscarmen/sing-box](https://github.com/fscarmen/sing-box) 的一键脚本：**一条命令**拉起菜单，按需选择、输入、配置；装完后再用 **一个命令** (`claude-maas`) 随时回到菜单改配置。

- ✅ 一键安装 / 更新 Claude Code CLI（官方原生脚本或 npm）
- ✅ 向导式填写 `ANTHROPIC_BASE_URL` / 鉴权 Token / 模型名
- ✅ **内置常用 MaaS 平台**（万界方舟 / DeepSeek / Kimi / 智谱 / Anthropic 官方 / 自定义），选一下就填好 Base URL
- ✅ **模型列表自管理**：不同 MaaS 的模型名不同，`claude-maas model add/rm/edit/primary/small` 命令随时增删改
- ✅ 两种落地方式：写入 Claude Code 的 `settings.json`，或写入系统环境变量
- ✅ 处理好 macOS / Linux / Windows 的环境变量差异
- ✅ 内置连接自测（真实打一次 `/v1/messages`）
- ✅ 一条命令进管理菜单，支持一键卸载与还原
- ✅ 只改自己写的东西（受管标记 + 自动备份），不动你已有的配置

> ⚠️ 本工具**只写它自己管理的那几个 `ANTHROPIC_*` 变量**，并且所有被修改的文件都会生成 `*.claude-maas.bak` 备份。即便如此，若你已经手工配置过 Claude Code，请先看一遍下文的「它到底改了什么」。

---

## 目录

- [快速开始](#快速开始)
- [菜单说明](#菜单说明)
- [内置 MaaS 平台](#内置-maas-平台)
- [模型列表管理](#模型列表管理)
- [两种写入方式怎么选](#两种写入方式怎么选)
- [三大平台的环境变量差异](#三大平台的环境变量差异)
- [`claude-maas` 管理命令](#claude-maas-管理命令)
- [支持的配置项](#支持的配置项)
- [连接自测](#连接自测)
- [卸载 / 还原](#卸载--还原)
- [它到底改了什么](#它到底改了什么)
- [安全说明](#安全说明)
- [常见问题 FAQ](#常见问题-faq)
- [附录：手动配置环境变量](#附录手动配置环境变量)
- [License](#license)

---

## 快速开始

> 下面的链接里分支名用的是 `main`。如果你把仓库默认分支设成了 `master`，把 URL 里的 `main` 换成 `master` 即可。

### macOS / Linux

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rynnwang/install-claude-cli-with-maas/main/claude-maas.sh)
```

没有 `curl` 就用 `wget`：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/rynnwang/install-claude-cli-with-maas/main/claude-maas.sh)
```

> 必须用 `bash <(...)`（进程替换）这种形式，**不要**用 `curl ... | bash` —— 管道会占用标准输入，菜单就没法读你的键盘输入了。

### Windows（PowerShell）

```powershell
irm https://raw.githubusercontent.com/rynnwang/install-claude-cli-with-maas/main/claude-maas.ps1 | iex
```

如果提示执行策略限制，先在**当前会话**放开（不改系统设置）：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; irm https://raw.githubusercontent.com/rynnwang/install-claude-cli-with-maas/main/claude-maas.ps1 | iex
```

### 首次运行会发生什么

1. 打印状态面板（Claude Code 是否已装、MaaS 是否已配、管理命令是否已装）。
2. 询问是否安装 `claude-maas` 管理命令（推荐 `y`）。之后你随时敲 `claude-maas` 就能回到这个菜单。
3. 进入主菜单。一般顺序是：`1` 装 CLI → `2` 配 MaaS → `4` 测试连接 → 新开终端跑 `claude`。

---

## 菜单说明

```
  1)  安装 / 更新 Claude Code CLI
  2)  配置 MaaS 连接 (平台 / Token / 模型)
  3)  查看当前配置
  4)  测试连接
  5)  启动 Claude Code
  6)  管理模型列表 (增 / 删 / 改 / 设主/快速)
  8)  安装 / 更新 "claude-maas" 管理命令
  9)  卸载 (配置 / 管理命令 / 可选卸载 CLI)
  0)  退出
```

| 项 | 作用 |
|---|---|
| **1 安装 / 更新** | 优先用官方原生安装脚本（`https://claude.ai/install.sh` / `install.ps1`，不需要 Node）；也可选 `npm i -g @anthropic-ai/claude-code`；或对已安装版本执行 `claude update`。 |
| **2 配置 MaaS** | ① 从[内置平台列表](#内置-maas-平台)选一个（自动填 Base URL）或选「自定义」；② 选鉴权方式（Bearer Token 或 API Key）；③ 从[模型列表](#模型列表管理)里选主模型 / 快速模型（也可现场输入新模型名，会自动加进列表）；④ 选写到哪（`settings.json` / 环境变量 / 都写）。Token 输入不回显，已有值直接回车保留。 |
| **3 查看配置** | 分别显示 `settings.json`、受管环境变量文件、系统级环境变量、**当前终端**里已生效的值、以及模型列表（标注 `[主]` `[快速]`）；密钥类自动打码。 |
| **4 测试连接** | 用「当前生效」的配置真实 `POST {BASE_URL}/v1/messages`（`max_tokens:1`），按 HTTP 状态码给出诊断（鉴权错 / 路径错 / 网络不通 / 模型名不对）。 |
| **5 启动 Claude Code** | 先把受管配置加载进当前进程，再启动 `claude`，省得你为验证专门重开终端。 |
| **6 管理模型列表** | 增 / 删 / 改模型名，把某个模型设为主模型（`ANTHROPIC_MODEL`）或快速模型（`ANTHROPIC_SMALL_FAST_MODEL`）。详见[模型列表管理](#模型列表管理)。 |
| **8 安装管理命令** | 把脚本自身装成 `claude-maas`（见下）。 |
| **9 卸载** | 逐项确认：清 `settings.json` 里的受管键、删环境变量、移除 shell 启动文件里的受管块、删配置目录（含模型列表）、删管理命令，可选连 Claude Code 本体一起卸。 |

---

## 内置 MaaS 平台

配置 MaaS（菜单 `2`）时，第一步从预置列表里选，会自动填好 `ANTHROPIC_BASE_URL` 并给出获取 API Key 的链接：

| 平台 | ANTHROPIC_BASE_URL | 获取 API Key |
|---|---|---|
| Anthropic 官方 | `https://api.anthropic.com` | https://console.anthropic.com/settings/keys |
| **万界方舟 WanJie Ark** | `https://maas-openapi.wanjiedata.com/api/anthropic` | https://www.wjark.com/center/api-key |
| DeepSeek | `https://api.deepseek.com/anthropic` | https://platform.deepseek.com/api_keys |
| 月之暗面 Kimi / Moonshot | `https://api.moonshot.cn/anthropic` | https://platform.moonshot.cn/console/api-keys |
| 智谱 GLM / BigModel | `https://open.bigmodel.cn/api/anthropic` | https://open.bigmodel.cn/usercenter/apikeys |
| 自定义 / 其它 | 手动输入 | — |

> ⚠️ 预置地址只是**便捷默认值**，各家路径/策略可能调整；请以对应平台官方文档为准。选中平台后 Base URL 仍可当场改。多数平台用 **Bearer Token**（写入 `ANTHROPIC_AUTH_TOKEN`）。

---

## 模型列表管理

不同 MaaS 平台的模型名各不相同、而且更新频繁，所以本工具**不内置具体模型名**，改为让你自己维护一份列表，存放在：

- macOS / Linux：`~/.config/claude-maas/models.txt`
- Windows：`%USERPROFILE%\.config\claude-maas\models.txt`

每行一个模型名。菜单 `6` 或下面的命令都能管理它；配置 MaaS 时的「主模型 / 快速模型」就是从这份列表里选（也可现场输入一个新名字，会自动加入列表）。

```bash
claude-maas models                      # 列出所有模型
claude-maas model add glm-4.6 glm-4.5-air   # 添加（可一次多个）
claude-maas model rm  glm-4.5-air        # 按名称删除
claude-maas model rm  2                  # 或按序号删除
claude-maas model edit glm-4.6 glm-4.6-latest   # 改名（会同步已设置的主/快速指针）
claude-maas model primary glm-4.6-latest # 设为主模型   -> ANTHROPIC_MODEL
claude-maas model small   glm-4.5-air    # 设为快速模型 -> ANTHROPIC_SMALL_FAST_MODEL
claude-maas model menu                   # 打开交互式管理菜单
```

`model primary` / `model small` 会把选中的模型名写回你**已经保存过**的位置（`settings.json` 和/或环境变量文件）；如果你还没配置过 MaaS，会提示先跑一次菜单 `2`。

---

## 两种写入方式怎么选

配置 MaaS 时会让你二选一（或都选）：

| | 方式 A：`settings.json`（推荐） | 方式 B：系统环境变量 |
|---|---|---|
| 落地位置 | `~/.claude/settings.json` 的 `env` 块 | 见下方各平台表 |
| 影响范围 | **只影响 Claude Code** | 影响所有会读 `ANTHROPIC_*` 的程序 |
| 跨平台一致性 | 三大平台完全一样 | 每个平台机制不同 |
| 是否动 shell 配置 | 否 | 是（Unix 注入 `~/.bashrc` 等；Windows 写用户环境变量） |
| 生效时机 | 下次启动 `claude` 即生效 | 需重开终端 / 重启已开的程序 |
| 依赖 | Unix 上需要 `jq` 或 `python3` 或 `node` 之一来安全改 JSON | 无 |

**建议**：只用 Claude Code → 选 A；还要给别的工具（自写脚本、其他 CLI）复用同一套变量 → 选 B 或「都写」。

> `settings.json` 的 `env` 是 Claude Code 官方支持的配置位；进程真实环境变量优先级更高。若你「都写」了、之后又只改其中一处，`3) 查看配置` 会把两处的值都列出来方便你对账。

---

## 三大平台的环境变量差异

当你选「方式 B：系统环境变量」时，本工具的落地方式：

| 平台 / Shell | 持久化机制 | 本工具写入 | 生效方式 |
|---|---|---|---|
| **Linux (bash)** | `~/.bashrc` / `~/.profile` 里 `export` | `~/.config/claude-maas/config.env` + 在 `~/.bashrc`、`~/.bash_profile`、`~/.profile` 注入受管块（`set -a; . config.env; set +a`） | 重开终端，或 `source ~/.bashrc` |
| **macOS (zsh，默认)** | `~/.zshrc` / `~/.zprofile` 里 `export` | 同上，外加写 `~/.zshrc` | 重开终端，或 `source ~/.zshrc` |
| **Linux/macOS (fish)** | `~/.config/fish/config.fish`（`set -gx`） | fish 语法的受管块，读同一个 `config.env` | 重开终端 |
| **Windows** | 用户环境变量（注册表 `HKCU\Environment`，等价于 `setx`） | `[Environment]::SetEnvironmentVariable(<name>, <value>, 'User')`，同时更新当前会话；另存一份 `%USERPROFILE%\.config\claude-maas\config.env` 备查 | 新开 PowerShell / CMD 窗口；已开的程序需重启 |

所有平台的密钥文件权限都会尽量收紧（Unix `chmod 600`；Windows 落在用户目录下）。

---

## `claude-maas` 管理命令

菜单里选 `8`（或首次运行时答 `y`）后安装。

**Unix**：脚本复制到 `~/.local/bin/claude-maas`。若 `~/.local/bin` 不在 `PATH`，会尝试追加到 `~/.bashrc` / `~/.zshrc` / `~/.profile`。

**Windows**：脚本复制到 `%USERPROFILE%\.config\claude-maas\claude-maas.ps1`，并
- 在该目录放一个 `claude-maas.cmd` 包装器；
- 把该目录加入用户 `PATH`；
- 在 PowerShell profile（`$PROFILE.CurrentUserAllHosts`）里加一个 `claude-maas` 函数。

之后（新开终端）可直接用：

```bash
claude-maas            # 打开交互菜单
claude-maas install    # 安装 / 更新 Claude Code CLI
claude-maas config     # 配置 MaaS 连接
claude-maas show       # 打印当前配置
claude-maas test       # 测试到 MaaS 的连接
claude-maas run        # 加载受管环境并启动 claude
claude-maas models     # 列出模型；model add/rm/edit/primary/small 见「模型列表管理」
claude-maas uninstall  # 移除配置 / 管理命令
claude-maas help       # 帮助
```

---

## 支持的配置项

向导会直接问前 4 个（其中两个模型名从[模型列表](#模型列表管理)里选）；其余可按需在 `settings.json` 或环境变量里自行添加，`claude-maas` 也会一并展示 / 清理它们。

| 变量 | 说明 |
|---|---|
| `ANTHROPIC_BASE_URL` | MaaS 接口根地址，例如 `https://your-maas.example.com/api`。工具会自动去掉结尾多余的 `/`。 |
| `ANTHROPIC_AUTH_TOKEN` | Bearer Token，作为 `Authorization: Bearer <token>` 发送。大多数中转平台用这个。 |
| `ANTHROPIC_API_KEY` | API Key，作为 `x-api-key` 头发送。与上一个二选一。 |
| `ANTHROPIC_MODEL` | 主模型名。留空则用 Claude Code 默认值。**具体可用名称以你的 MaaS 平台文档为准。** |
| `ANTHROPIC_SMALL_FAST_MODEL` | 轻量 / 快速任务用的模型名，留空则用默认。 |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` / `ANTHROPIC_DEFAULT_SONNET_MODEL` / `ANTHROPIC_DEFAULT_HAIKU_MODEL` | 分别覆盖 Opus / Sonnet / Haiku 档位映射到的实际模型名。 |
| `API_TIMEOUT_MS` | 请求超时（毫秒）。网关较慢时可调大。 |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | 单次回复的最大输出 token 上限。 |

---

## 连接自测

菜单 `4` / `claude-maas test` 会：

1. 按「当前进程环境变量 → `settings.json` → `config.env`」的优先级解析出生效值；
2. 向 `{ANTHROPIC_BASE_URL}/v1/messages` 发一个最小请求；
3. 按结果给提示：

| 结果 | 含义 |
|---|---|
| `HTTP 200` | 连接与鉴权都正常 ✅ |
| `HTTP 400` | 已连通、鉴权大概率没问题；通常是**模型名**不被网关接受 |
| `HTTP 401 / 403` | 鉴权失败，检查 Token / API Key（或额度、权限） |
| `HTTP 404` | 路径不对，检查 `BASE_URL` 是否需要加 / 去掉 `/v1`、`/api` 之类前缀 |
| `HTTP 000` / 连接异常 | DNS / 网络 / TLS 层面就没通 |

---

## 卸载 / 还原

```bash
claude-maas uninstall
```

或菜单选 `9`。会逐项确认：

- 清除 `settings.json` 里由本工具写入的 `ANTHROPIC_*` 键（保留其它设置）
- 删除系统 / 用户级环境变量（仅受管的那几个）
- 移除 shell 启动文件（`~/.bashrc` 等 / PowerShell profile）里的受管块
- 从 `PATH` 移除、删除配置目录 `~/.config/claude-maas`
- 删除 `claude-maas` 管理命令
- （可选）连 Claude Code CLI 本体一起卸载

每个被改动的文件在改动前都会留一份 `*.claude-maas.bak`。

---

## 它到底改了什么

| 路径 | 何时写 | 内容 |
|---|---|---|
| `~/.claude/settings.json` | 选「方式 A / 都写」 | 仅新增 / 更新 / 删除 `env` 下的受管键，其余原样保留；改前备份为 `settings.json.claude-maas.bak` |
| `~/.config/claude-maas/config.env` | 选「方式 B / 都写」 | `KEY='value'` 形式，仅受管键；`chmod 600` |
| `~/.config/claude-maas/models.txt` | 用菜单 `6` 或 `model` 命令 | 你的模型名列表，每行一个（纯本地，不影响任何环境） |
| `~/.bashrc`、`~/.bash_profile`、`~/.zshrc`、`~/.profile` | 选「方式 B / 都写」（Unix） | 在 `# >>> claude-maas >>>` / `# <<< claude-maas <<<` 之间的一段；每个文件备份为 `<file>.claude-maas.bak` |
| `~/.config/fish/config.fish` | 同上且检测到 fish | fish 语法的受管块 |
| `~/.local/bin/claude-maas` | 安装管理命令（Unix） | 脚本副本 |
| `%USERPROFILE%\.config\claude-maas\` | 安装管理命令（Windows） | `claude-maas.ps1` + `claude-maas.cmd` |
| 用户 `PATH`、PowerShell `$PROFILE.CurrentUserAllHosts` | 安装管理命令（Windows） | 追加目录到 PATH；profile 里加 `claude-maas` 函数（同样在受管标记之间） |
| 用户环境变量（`HKCU\Environment`） | 选「方式 B / 都写」（Windows） | 仅受管的 `ANTHROPIC_*` 等键 |

**不会**触碰：你已经手工设置的、不在受管列表里的任何变量；`settings.json` 里 `env` 之外的任何字段；受管标记之外的任何行。

---

## 安全说明

- Token / API Key 以明文存放在 `settings.json` 或 `config.env` —— 这与 Claude Code 本身的存储方式一致。Unix 下文件权限设为 `600`。
- 请勿把 `config.env`、`settings.json`、或任何 `*.claude-maas.bak` 提交到版本库（本仓库 `.gitignore` 已覆盖常见情况，但那是给**本项目**用的；你自己的项目请自行忽略 `~/.claude`）。
- 脚本通过 `curl | bash` / `irm | iex` 运行前，建议先在浏览器打开 raw 链接看一眼内容。
- 连接自测只把凭据发到你自己填写的 `ANTHROPIC_BASE_URL`，不发往任何第三方。

---

## 常见问题 FAQ

**Q：装完 `claude` 命令找不到？**
A：多半是 `PATH` 没刷新。新开一个终端；或 Unix 上 `source ~/.zshrc`（bash 用 `~/.bashrc`）。官方原生安装器通常装在 `~/.local/bin`。

**Q：Unix 上选 `settings.json` 方式报「需要 jq / python3 / node」？**
A：三者装任意一个即可（`brew install jq` / `apt install jq` …），或改用「系统环境变量」方式。

**Q：我之前已经手工配过 Claude Code 的 MaaS，跑这个会冲掉吗？**
A：不会冲掉不相干的东西。但如果你手工设过**同名**的 `ANTHROPIC_BASE_URL` 等，且这次选了写入同一个位置，那自然会被本次输入的值覆盖（并留有 `.bak`）。想先看现状就先跑 `claude-maas show`。

**Q：Windows 上 `claude-maas` 敲了没反应 / 找不到？**
A：安装管理命令后需要**新开**一个 PowerShell 窗口。急用可直接跑 `& "$HOME\.config\claude-maas\claude-maas.ps1"`。

**Q：`irm | iex` 提示脚本未数字签名 / 执行策略？**
A：用快速开始里带 `Set-ExecutionPolicy -Scope Process Bypass` 的那条命令，只对当前会话生效，不改系统。

**Q：企业代理 / 自签证书环境？**
A：本工具不额外处理代理。Claude Code 与 `curl` 会读取标准的 `HTTPS_PROXY` / `NODE_EXTRA_CA_CERTS` 等变量，按需自行设置。

---

## 附录：手动配置环境变量

如果你不想用脚本，只想知道「手动怎么设」：

### Linux / macOS（bash 或 zsh）

```bash
# 写入对应的启动文件（bash: ~/.bashrc，zsh: ~/.zshrc）
cat >> ~/.zshrc <<'EOF'
export ANTHROPIC_BASE_URL="https://your-maas.example.com/api"
export ANTHROPIC_AUTH_TOKEN="sk-xxxxxxxx"
export ANTHROPIC_MODEL="<模型名>"
EOF
source ~/.zshrc
```

### fish

```fish
set -Ux ANTHROPIC_BASE_URL "https://your-maas.example.com/api"
set -Ux ANTHROPIC_AUTH_TOKEN "sk-xxxxxxxx"
set -Ux ANTHROPIC_MODEL "<模型名>"
```

### Windows（PowerShell，持久化到用户级）

```powershell
[Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', 'https://your-maas.example.com/api', 'User')
[Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'sk-xxxxxxxx', 'User')
[Environment]::SetEnvironmentVariable('ANTHROPIC_MODEL', '<模型名>', 'User')
# 新开窗口生效
```

### Windows（CMD）

```bat
setx ANTHROPIC_BASE_URL "https://your-maas.example.com/api"
setx ANTHROPIC_AUTH_TOKEN "sk-xxxxxxxx"
setx ANTHROPIC_MODEL "<模型名>"
```

### 不改环境变量，只给 Claude Code（所有平台）

编辑 `~/.claude/settings.json`（Windows：`%USERPROFILE%\.claude\settings.json`）：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://your-maas.example.com/api",
    "ANTHROPIC_AUTH_TOKEN": "sk-xxxxxxxx",
    "ANTHROPIC_MODEL": "<模型名>"
  }
}
```

---

## License

[MIT](LICENSE) © Rynn Wang

本项目与 Anthropic 无隶属关系。“Claude”“Claude Code” 为 Anthropic 的商标。
