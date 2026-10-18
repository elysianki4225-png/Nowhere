# Nowhere (NW3) 一键部署脚本

[Nowhere](https://github.com/NodePassProject/Nowhere) 协议（NW3）的 Linux 一键安装与运维脚本库：
自动从 GitHub Releases 安装官方 `nowhere` 二进制，生成 systemd 服务，并提供交互式菜单管理
Portal / Vector / Egress 三种角色。

- 上游协议：<https://github.com/NodePassProject/Nowhere>
- English: [README.en.md](README.en.md)
- 许可证：GPL-3.0-or-later（与上游一致）

## 它是什么

Nowhere 把 TCP / UDP 流量通过 **TLS / QUIC** 中继到你选择的出口。一个二进制提供三种角色：

```
              TLS / QUIC                      QUIC
+----------+                 +----------+                 +----------+
|  Vector  |---------------->|  Portal  |<----------------|  Egress  |
| (客户端)  |                 | (服务端)  |                 | (远端出口) |
+----------+                 +----------+                 +----------+
     |                            |  direct / SOCKS5            |
     v                            v                             v
  本地 SOCKS5                  目标 Target                    目标 Target
```

| 角色 | 作用 | 部署位置 |
| --- | --- | --- |
| **Portal** | 服务端中继：监听 TLS+QUIC，把流量送往 direct / SOCKS5 / Egress 出口 | 有公网的 VPS |
| **Vector** | 客户端：本地开 SOCKS5 入口，连到 Portal | 本地电脑 / 内网主机 |
| **Egress** | 远端出口：QUIC 回连 Portal，由它访问目标 | 需要"落地"的主机（无需入站端口） |

## 功能特性

- **一键安装**：`curl | bash` 即可完成下载、校验、配置、开机自启
- **安全下载**：从 GitHub Releases 获取官方二进制，并按 Release API 提供的 SHA-256 校验
- **交互式向导**：每一步回车取默认值；也可完全非交互（`--yes` + 参数）
- **三角色全覆盖**：Portal（direct / SOCKS5 / Egress 出口）、Vector、Egress
- **systemd 托管**：每实例一个服务（`nowhere-<名称>`），崩溃自动重启，支持低端口绑定
- **客户端链接**：自动生成 `nowhere://` 分享链接与 `vector://` 客户端 URL，支持二维码
- **证书指纹**：一键获取 Portal 自签名证书 SHA-256 并写入 `pin`
- **中英双语**：自动识别系统语言，也可 `--lang zh|en` 或菜单切换
- **运维命令**：状态、日志、探活（probe）、限速、更新、卸载一应俱全

## 环境要求

- Linux（x86_64 / aarch64，glibc 或 musl），systemd
- `curl`、`tar`；root 权限
- 可选：`qrencode`（显示二维码）、`openssl`（密钥生成兜底）
- FreeBSD / macOS 可安装二进制并前台运行（`nw run <名称>`），暂不支持 systemd 托管

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/elysianki4225-png/Nowhere/main/install.sh | sudo bash
```

首次运行进入交互式向导：选角色 → 选端口/出口 → 自动生成密钥 → 自动配置并启动服务。

> 国内网络无法访问 `raw.githubusercontent.com` 时，可用镜像：
>
> ```bash
> curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/elysianki4225-png/Nowhere/main/install.sh | sudo bash
> ```

## 快速开始

### 1. Portal（服务端，例如一台 VPS）

```bash
sudo bash install.sh portal --yes
# 等价于：nw.sh portal --port 2000 --carrier same --out direct --morph 1
```

装完会打印客户端链接，例如：

```
nowhere://<KEY>@1.2.3.4:2000?morph=1                       # 分享链接
vector://<KEY>@1.2.3.4:2000?in=127.0.0.1:1080&morph=1&pin=<证书指纹>
```

**记得在 VPS 防火墙和云安全组放行 TCP+UDP 2000。**

### 2. Vector（客户端，本地机器）

```bash
sudo bash install.sh vector --yes \
  --portal-host 1.2.3.4 --portal-port 2000 \
  --in 127.0.0.1:1080
```

随后把应用代理指向 SOCKS5 `127.0.0.1:1080` 即可。自签名证书场景建议带上 `pin`：

```bash
sudo bash install.sh vector --portal-host 1.2.3.4 --portal-port 2000 --pin <64位十六进制>
```

### 3. Egress（远端出口，无需入站端口）

先在 Portal 上使用 `out=egress`（脚本会自动补上 QUIC 监听）：

```bash
sudo bash install.sh portal --out egress --yes
```

再到出口主机回连：

```bash
sudo bash install.sh egress --portal-host 1.2.3.4 --portal-port 2000 --pin <64位十六进制>
```

## 交互式管理菜单

```bash
sudo nw menu        # 安装后即可使用（等价于 bash nw.sh menu）
```

菜单中可查看各实例状态、启停服务、跟踪日志、打印客户端链接、重新配置、更新、卸载。

## 常用命令

| 命令 | 说明 |
| --- | --- |
| `nw menu` | 交互式管理菜单 |
| `nw list` | 列出所有实例及状态 |
| `nw status` | 服务状态 + `nowhere status` 遥测 |
| `nw start \| stop \| restart [名称\|--all]` | 服务生命周期 |
| `nw logs <名称> [-f]` | 查看 / 跟踪 systemd 日志 |
| `nw link [名称]` | 打印客户端链接 + 二维码 |
| `nw key` | 生成 32 位十六进制共享密钥 |
| `nw pin <名称> [--apply]` | 获取证书指纹，`--apply` 写入配置并重启 |
| `nw probe <名称> <主机:端口>` | 通过 Portal 真实建立一次 TCP Flow 验证配置 |
| `nw run <名称>` | 前台运行（无 systemd 环境） |
| `nw update` | 更新脚本自身与 nowhere 二进制，并重启实例 |
| `nw uninstall <名称\|--all>` | 卸载实例（可顺带删除二进制） |
| `nw version` | 显示脚本与二进制版本 |
| `nw lang zh\|en` | 切换界面语言 |

## 非交互安装参数

```bash
bash nw.sh <portal|vector|egress|install> [选项]
```

| 选项 | 说明 | 默认值 |
| --- | --- | --- |
| `--role ROLE` | `portal` / `vector` / `egress` | 向导选择 |
| `--name NAME` | 实例名，服务为 `nowhere-<NAME>` | 角色名 |
| `--key HEX` | 32 位小写十六进制共享密钥 | 自动生成 |
| `--port PORT` | Portal 监听端口 | `2000` |
| `--tcp-port` / `--udp-port` | TCP/UDP 独立端口 | — |
| `--carrier MODE` | `same` / `split` / `tcp` / `udp` | `same` |
| `--out MODE` | Portal 出口：`direct` / `socks` / `egress` | `direct` |
| `--socks [user:pass@]host:port` | SOCKS5 上游（`--out socks` 时） | — |
| `--portal-host HOST` | Vector/Egress 的 Portal 地址 | 必填 |
| `--portal-port PORT` | Vector/Egress 的 Portal 端口 | `2000` |
| `--net tcp\|udp` | Vector 连接载体 | `tcp` |
| `--in [user:pass@]host:port` | Vector 本地 SOCKS5 监听 | `127.0.0.1:1080` |
| `--in-auth USER:PASS` | SOCKS5 认证 | 无 |
| `--pin HEX64` | 证书 SHA-256 pin | 无 |
| `--sni NAME` | 校验用服务名 | 端点主机名 |
| `--morph 0\|1` | 线路伪装（两端需一致） | `1` |
| `--rate N` / `--etar N` | 上传 / 下载限速（Mbps，0 不限） | `0` |
| `--tls 1\|2` `--crt P` `--key P` | 自签名(1) 或 PEM 证书(2) | `1` |
| `--public-addr ADDR` | 客户端链接中的对外地址 | 自动探测 |
| `--version TAG` | 安装指定 Release（如 `v3.0.1`） | 最新 |
| `--open-firewall` | 自动放行 ufw / firewalld 端口 | 否 |
| `--yes` | 非交互，全部取默认值 | 否 |
| `--lang zh\|en` | 界面语言 | 自动识别 |

环境变量：`NW_REF`（脚本分支）、`NW_RAW_BASE`（脚本源，可指向镜像）、`NW_PREFIX`（默认
`/usr/local`）、`NW_ETC`（默认 `/etc/nowhere`）、`NW_VERSION`（固定上游版本）、
`NW_LOCAL_TARBALL`（本地归档安装）、`NW_SKIP_VERIFY=1`（跳过校验，不推荐）。

## 目录结构

```
/usr/local/bin/nowhere            # 官方二进制
/usr/local/bin/nw                 # 本管理脚本
/usr/local/bin/nowhere-<名称>      # 实例启动包装（读取 url 文件）
/etc/nowhere/<名称>/url            # 运行 URL（角色、密钥、参数，0600 级别目录）
/etc/nowhere/<名称>/meta           # 实例元数据（管理用）
/etc/nowhere/<名称>/env            # 可选：NOW_* 运行期调优
/etc/systemd/system/nowhere-<名称>.service
```

修改配置请重新运行向导或用 `nw pin --apply`，直接编辑 `url` 文件后 `nw restart <名称>` 亦可。

## 防火墙

- Portal：放行 **TCP + UDP** 监听端口（默认 2000），云安全组同样要放
- Vector：只需本地 SOCKS5 端口可被应用访问
- Egress：**无需任何入站端口**（主动 QUIC 回连）

脚本会自动识别 `ufw` / `firewalld` 并给出命令；加 `--open-firewall` 可自动放行。

## 安全说明

- 共享密钥（32 hex）是唯一凭证，请通过可信渠道分发，两端保持一致
- 自签名证书（`tls=1`）下客户端**必须**配置 `pin`（`nw pin <portal实例>` 可获取）
- 有域名和 CA 证书时优先 `tls=2` + `crt/key`，客户端走系统 CA + 主机名校验
- 服务以 root 运行（可能需要绑定低端口）；已启用 `NoNewPrivileges`

## 常见问题

**Q：安装后客户端连不上？**
按顺序检查：① Portal 端口 TCP+UDP 是否放行（含云安全组）；② 两端密钥是否一致；
③ `morph` 是否一致（默认 1）；④ 自签名证书是否配置了 `pin`；
⑤ 用 `nw probe <portal实例> example.com:443` 验证真实建流。

**Q：`nowhere status` 没有输出？**
`status` 通过本地 IPC 读取运行中的实例，请以 root 运行，并确认服务在跑
（`nw list` 查看状态）。

**Q：如何同时跑多个 Portal / Vector？**
用 `--name` 区分实例，例如 `bash nw.sh portal --name p2 --port 3000`，
服务名为 `nowhere-p2`，配置在 `/etc/nowhere/p2/`。

**Q：如何升级？**
`sudo nw update`：更新脚本自身 + 最新二进制并重启所有实例；
`nw update --version v3.0.1` 可锁定版本。

**Q：完全卸载？**
`sudo nw uninstall --all`，确认后删除二进制。

## 相关项目

- [Nowhere](https://github.com/NodePassProject/Nowhere) — 协议与官方二进制（上游）
- [nowhere-sh](https://github.com/NodePassProject/nowhere-sh) — 官方 Linux 部署脚本
- [Anywhere](https://github.com/NodePassProject/Anywhere) — Apple 平台原生客户端
- [NowhereDash](https://github.com/NodePassProject/NowhereDash) — Web 舰队运维面板

## 免责声明

本项目仅为上游 Nowhere 协议的安装运维辅助脚本，不分发、不修改官方二进制。
请遵守所在地区法律法规，非法用途后果自负。

## 许可证

[GPL-3.0-or-later](LICENSE)，与上游 Nowhere 保持一致。
