# Snell v6 关闭原生加密 + REALITY 一键部署

> **更新：已有 [sing-box 原生版](../README.md)，两端各运行一个 sing-box 1.14.4，无需 Xray 桥接，可导入完整 JSON 或使用远程配置导入链接。以下文档保留为旧版 Xray 桥接方案说明。**

在 VPS 安装官方 Snell v6，将 `mode` 设为 `unsafe-raw`，由 Xray 的 **VLESS over REALITY** 通道承载流量。Snell 明文服务仅监听 `127.0.0.1`，公网入口默认是 `443/TCP`。

**客户端也需要 Xray 桥接。** 本方案适合可以运行 Xray 的电脑或路由器；Surge Mac 可以连接本机桥接端口。Surge iOS 单独运行时无法按这套配置启动旁路 Xray，不能只导入 Snell 一行配置就直接连接 VPS。

```text
Surge / sing-box（Snell v6，unsafe-raw）
    │ 本机 TCP 127.0.0.1:23456
    ▼
客户端 Xray 26.11.9
    │ VLESS + REALITY，加密 TCP
    ▼
VPS Xray :443
    │ 固定转发到 127.0.0.1:23456
    ▼
官方 snell-server v6.0.0（unsafe-raw）→ 目标网站
```

VLESS 不额外启用协议加密，也不启用 Vision flow。Snell 自身的加密与混淆均关闭，外层 REALITY 提供传输加密。仍然保留 Snell 的协议封装与转发逻辑，因此没有“完全零开销”或确定的提速保证。

## VPS 安装

支持 **Debian 11+ / Ubuntu 22.04+、amd64 / arm64、systemd**。需要 root 权限和可用的出站网络。不支持 Alpine、普通 Docker 容器或 OpenRC。

将 `snell-reality.sh` 上传到 VPS 后执行；将示例地址替换为你的 VPS 公网 IP 或域名：

```bash
sudo bash snell-reality.sh install --server 203.0.113.10
```

也可以自动检测公网 IP：

```bash
sudo bash snell-reality.sh install
```

NAT VPS、经过 HTTP 代理的环境请显式指定 `--server`。使用域名时，该域名应直接解析到 VPS，不能经过普通 HTTP CDN 代理。

自定义入口与 REALITY 目标：

```bash
sudo bash snell-reality.sh install \
  --server proxy.example.com \
  --port 8443 \
  --sni www.cloudflare.com
```

IPv6 示例，IPv6 参数不带方括号：

```bash
sudo bash snell-reality.sh install --server 2001:db8::10 --listen ::
```

默认参数：

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `--port` | `443` | VPS 的 REALITY TCP 入口 |
| `--sni` | `www.cloudflare.com` | REALITY 目标域名，目标端口固定为 443 |
| `--listen` | `0.0.0.0` | 输入 IPv6 地址时默认改为 `::`；域名的 IPv6 部署请显式指定 |
| `--snell-port` | `23456` | VPS 上 Snell 回环端口 |
| `--client-port` | `23456` | 客户端 Xray 回环端口 |
| `--socks-port` | `1080` | 可选 sing-box 客户端的本地 SOCKS/HTTP 端口 |

脚本会从当前 VPS 检查目标网站的证书、TLS 1.3 和 h2。目标需要从 VPS 可访问且适合 REALITY；TLS 检查通过不等于保证所有网络环境都可连接。目标不可达时可用 `--sni` 更换。无需购买域名或申请自己的 TLS 证书。

安装完成后，在 VPS 防火墙和云安全组中**放行所选 REALITY TCP 端口**。例如使用 UFW 且入口为 443 时：

```bash
sudo ufw allow 443/tcp
```

脚本不会启用、关闭或重写防火墙。无需开放 Snell 回环端口或额外的入站 UDP 端口。Snell 的 UDP 流量通过 TCP 隧道传输；VPS 的出站规则仍需允许目标流量。

## 客户端：Surge Mac

1. 下载 [Xray-core v26.11.9](https://github.com/XTLS/Xray-core/releases/tag/v26.11.9) 对应系统的官方程序。Apple Silicon 使用 `Xray-macos-arm64-v8a.zip`，Intel Mac 使用 `Xray-macos-64.zip`。使用同一版本可以避免 REALITY 指纹兼容问题。
2. 从 VPS 取回 `xray-bridge.json` 和 `surge-snippet.conf`。下面假设已允许 root SSH；也可用你的 SSH 管理账户在 VPS 上执行 `sudo cat` 后保存文件。

```bash
scp root@你的VPS地址:/etc/snell-reality/clients/xray-bridge.json .
scp root@你的VPS地址:/etc/snell-reality/clients/surge-snippet.conf .
chmod 600 xray-bridge.json surge-snippet.conf
```

3. 在客户端运行 Xray，保持该进程运行：

```bash
./xray run -config ./xray-bridge.json
```

4. 使用支持 Snell v6 `unsafe-raw` 的 Surge，把 `surge-snippet.conf` 中的节点行放入现有配置的 `[Proxy]` 节。把该节点加入你的代理组，并让相应规则选择它。生成的节点形式如下，PSK 以实际输出为准：

```ini
[Proxy]
Snell-REALITY = snell, 127.0.0.1, 23456, psk=实际生成的PSK, version=6, mode=unsafe-raw, reuse=true
```

开启 Surge Mac 增强模式时，将下面规则放在现有 `[Rule]` 节中的兜底规则之前，防止 Xray 的外层连接再次进入代理而形成循环：

```ini
PROCESS-NAME,xray,DIRECT
```

这个 `127.0.0.1` 指客户端自己的电脑。不要把节点地址改成 VPS 公网 IP：VPS 公网入口接收的是 REALITY，不能直接接收 Snell。

本项目没有在实际 Surge 应用中测试 UI 导入；已使用支持 Snell v6 的 sing-box 客户端对相同本地桥接链路做真实协议测试。

## 客户端：Linux / Windows / macOS 的 sing-box

先按上文运行 Xray 桥接，再取回 `/etc/snell-reality/clients/sing-box-via-bridge.json`。使用 **sing-box 1.14.4** 或经验证兼容的版本：

```bash
sing-box check -c sing-box-via-bridge.json
sing-box run -c sing-box-via-bridge.json
```

应用的 SOCKS5 或 HTTP 代理设为 `127.0.0.1:1080`。用远端 DNS 的 SOCKS5 请求检查公网连接：

```bash
curl --proxy socks5h://127.0.0.1:1080 https://example.com
```

这里的配置是普通本地代理，不会自动启用 TUN 或修改系统代理。若另外配置全局接管，需让 Xray 的外层连接走直连。

**为何保留 Xray 桥接？** 在本项目验证的版本中，sing-box 1.14.4 的 REALITY 客户端会移除 X25519MLKEM768，而 Xray 26.11.9 的 REALITY 服务端要求相应现代 ClientHello。直接将这两个版本的 REALITY 出入站相连会失败。交付配置让 Xray 同版本负责两端 REALITY，sing-box 仅负责 Snell v6。

此外，外层 VLESS 出口被固定转发到 Snell；它不是可以单独导入常规 VLESS 客户端、直接代理网页的节点。

## 管理与卸载

```bash
sudo snell-reality show       # 显示节点参数和客户端文件位置，包含凭据
sudo snell-reality check      # 配置、服务和本机监听检查
sudo snell-reality status
sudo snell-reality restart
sudo snell-reality stop
sudo snell-reality start
sudo snell-reality logs       # Ctrl-C 退出
sudo snell-reality uninstall  # 输入 yes 后删除专用服务、配置和密钥
```

无人值守卸载可使用 `sudo snell-reality uninstall --yes`。卸载保留系统依赖以及用户自己配置的防火墙规则。

`install` 重复执行会保留已有配置。首次安装选项不用于重配置现有安装。如果需要换入口、SNI 或密钥，可以先保存客户端文件，卸载后重新安装，并将新客户端配置分发到自己的设备。

`upgrade` 只升级到**当前执行脚本固定的版本**，不是自动追踪 latest。未来更换脚本时执行 `sudo bash 新版脚本.sh upgrade`；升级保留连接参数，成功后启动并启用服务。请同时遵循新版的客户端版本要求。

## 文件、权限与实现

| 位置 | 内容 |
| --- | --- |
| `/etc/snell-reality/snell.conf` | Snell 配置，`127.0.0.1` + `unsafe-raw` |
| `/etc/snell-reality/xray.json` | REALITY 服务端配置 |
| `/etc/snell-reality/state.json` | 安装状态及密钥，root 只读写 |
| `/etc/snell-reality/clients/` | 客户端配置，目录 700、文件 600 |
| `/usr/local/lib/snell-reality/` | 专用 Snell / Xray 程序 |
| `/usr/local/sbin/snell-reality` | 管理脚本 |
| `snell-reality-snell.service` | Snell systemd 服务 |
| `snell-reality-xray.service` | REALITY systemd 服务 |

服务使用专用的 `snell-reality` 系统账户运行。安装检查架构、已有文件、已有用户和端口占用；生成随机 PSK、UUID、X25519 密钥与 short ID。客户端下载不包含 REALITY 私钥。下载、配置验证完成后才替换程序与配置，部署失败时回滚专用文件与服务状态。

如果恢复操作本身遇到磁盘或服务错误，脚本会返回失败并保留原始备份，终端会显示备份目录供手动恢复。

固定版本为 Snell **6.0.0**、Xray **26.11.9**，下载启用 HTTPS 证书校验并检查脚本内固定的 SHA-256。Snell 摘要来自开发时下载的官方发布包，不是上游单独提供的签名证明；Xray 摘要同时对照了 GitHub Release asset digest。更换版本时必须同时重新验证兼容性与两个架构的摘要，不能只修改版本号。

## 验证记录与限制

2026-11-17，在 Linux amd64 开发环境完成：

- `bash -n` 与 ShellCheck 0.11.0 静态检查。
- Xray 26.11.9、sing-box 1.14.4 对生成配置的实际解析检查。
- 官方 Snell 6.0.0 + Xray 双端 + sing-box Snell 客户端，实际传输并逐字节校验 1,121,000 字节的 HTTP 内容，复用连接再次请求。
- 经同一 REALITY TCP 隧道转发 32、1200、4096 字节的 UDP 数据报并校验回包。
- 错误 REALITY short ID 无法取得后端内容。
- 输入注入、端口、IPv4/IPv6 字面量、密钥导出隔离、文件权限检查。
- 升级失败恢复、首次安装失败清理、退出状态保留测试；其中 systemctl / userdel 使用模拟实现。
- systemd 单元在用户验证模式下通过语法和程序路径检查。

测试使用回环网络与临时 TLS 1.3 目标。**未在你的 VPS 上部署，未验证公网、防火墙、不同发行版的完整安装，也未执行 arm64 程序或实际 Surge 客户端。** arm64 官方下载包及摘要已核对。安装后的 `check` 是本机健康检查，公网仍需使用客户端实测。

开发者可自行下载上述官方程序，执行：

```bash
bash -n snell-reality.sh
shellcheck -x --source-path=SCRIPTDIR snell-reality.sh tests/rollback.sh
bash tests/rollback.sh
python3 tests/verify.py \
  --snell /path/to/snell-server \
  --xray /path/to/xray \
  --sing-box /path/to/sing-box
```

测试不需要 root，不安装服务，不监听公网端口，不使用你的真实配置或密钥。

## 依据

- [Snell 官方发布说明：v6 模式、两端模式一致要求、下载地址](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell)
- [Xray-core v26.11.9](https://github.com/XTLS/Xray-core/releases/tag/v26.11.9)
- [Xray Freedom `finalRules` 配置实现](https://github.com/XTLS/Xray-core/blob/v26.11.9/infra/conf/freedom.go)：为固定回环 Snell TCP 端口添加精确放行规则。
- [sing-box 1.14.4 的 REALITY 客户端实现](https://github.com/SagerNet/sing-box/blob/v1.14.4/common/tls/reality_client.go)
- [REALITY 服务端 ClientHello 校验](https://github.com/XTLS/REALITY/blob/4a26e87788f5e08cb9d433c1fab94bc15a8bf653/tls.go)

本文件介绍旧版兼容方案。新部署请优先阅读 [原生版安装说明](../README.md)。
