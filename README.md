# 原生 sing-box：Snell v6 unsafe-raw + REALITY

**两端都使用 sing-box 1.14.4，每端一个进程，客户端无需 Xray 桥接。** sing-box 从 1.14.0 起原生支持 Snell 入站与出站；本版使用稳定版 1.14.4，并已验证完整 TCP / UDP 链路。

客户端通过 `detour` 将 Snell v6 `unsafe-raw` 出站交给 VLESS + REALITY 出站。服务端先终止 REALITY，再把解出的 TCP 数据固定转发到同一进程中监听回环地址的 Snell 入站：

```text
客户端 sing-box
  应用 → Snell v6 unsafe-raw 出站 → detour: VLESS + REALITY 出站
                                       │ 公网加密 TCP
VPS sing-box                           ▼
  VLESS + REALITY 入站 → 固定转发 127.0.0.1:23456 → Snell v6 unsafe-raw 入站 → 目标
```

Snell 与 REALITY 由 sing-box 的两个原生协议配置串联，通过 `detour` 保留完整链路。

## 安装

支持 Debian 11+ / Ubuntu 22.04+，amd64 / arm64，运行中的 systemd。在 VPS 上下载并安装，将最后的地址替换为自己的公网 IP：

```bash
curl -fL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/mutsuki14/snell-v6-reality/main/snell-reality-native.sh \
  -o snell-reality-native.sh && \
sudo bash snell-reality-native.sh install --server 你的VPS公网IP
```

如果已经下载或上传了脚本，直接执行：

```bash
sudo bash snell-reality-native.sh install --server 你的VPS公网IP
```

不提供 `--server` 时会尝试自动检测公网 IP。NAT VPS 或设置了 HTTP 代理时请显式指定公网地址。使用域名时应直接解析到 VPS。

默认参数：

| 参数 | 默认 | 用途 |
| --- | --- | --- |
| `--port` | `443` | REALITY TCP 入口 |
| `--sni` | `www.cloudflare.com` | REALITY 目标，目标端口固定 443 |
| `--listen` | `0.0.0.0` | IPv6 地址自动选择 `::`；使用域名的 IPv6 部署请显式指定 |
| `--snell-port` | `23456` | Snell 的 VPS 回环端口 |
| `--socks-port` | `1080` | 客户端 mixed 本地代理端口 |
| `--profile-url` | 空 | 可选的 HTTPS 完整配置下载地址，用于输出导入链接 |

例如：

```bash
sudo bash snell-reality-native.sh install \
  --server proxy.example.com --port 8443 --sni www.cloudflare.com
```

脚本会检查端口占用、下载摘要、目标站点的证书/TLS 1.3/h2，生成随机 PSK、UUID、REALITY 密钥和 short ID，安装非 root systemd 服务，并导出客户端配置。部署失败会恢复本版原有文件及服务状态；若恢复本身失败，会保留备份并显示路径。

请在 VPS 防火墙和云安全组放行所选的 TCP 入口。无需开放 `23456` 或入站 UDP；Snell UDP 流量通过同一个 TCP 隧道传输。脚本不修改防火墙。

## 一次导入完整配置

安装后生成两个**完整配置文件**，都包含 Snell、REALITY 以及 `detour` 关系：

| 文件 | 使用场景 |
| --- | --- |
| `/etc/snell-reality-native/clients/client-mixed.json` | 桌面命令行或路由器，提供本地 SOCKS5/HTTP 代理 |
| `/etc/snell-reality-native/clients/client-tun.json` | 接受完整 sing-box TUN 配置的客户端，用于系统流量接管 |

获取自己需要的文件后，在客户端选择从文件导入。客户端内置核心应支持 sing-box 1.14.4 配置；只接受普通节点 URI 或会转换、丢弃 `detour` 字段的客户端不能直接使用。

`client-tun.json` 包含 IPv4/IPv6 TUN 地址、自动路由、DNS 劫持和通过 Snell 转发的 DNS。代理服务器域名使用独立的本地引导解析器。TUN 配置已通过核心解析检查，具体系统的 VPN/TUN 授权与实际接管仍需在客户端验证。

桌面命令行示例，客户端安装 sing-box 1.14.4 后运行：

```bash
sing-box check -c client-mixed.json
sing-box run -c client-mixed.json
```

另开终端验证：

```bash
curl --proxy socks5h://127.0.0.1:1080 https://example.com
```

**不要把 Snell 出站中的 `127.0.0.1` 改成 VPS 地址。** 它通过 `detour` 请求远端转发，表示 VPS 的 Snell 回环服务；真正的 VPS 公网地址位于 REALITY 出站中。

## 分享链接 / 远程配置导入

可以生成官方支持的完整配置导入链接：

```text
sing-box://import-remote-profile?url=经过编码的HTTPS配置地址#Snell-REALITY
```

它指向**完整 JSON 配置**，因此可以同时导入 Snell 与 REALITY 的链式关系。它与只描述一个出站的普通 `snell://` 或 `vless://` 节点链接不同。

先将自己的 `client-tun.json` 放到自己控制的 HTTPS 下载地址，再生成链接：

```bash
bash snell-reality-native.sh import-link \
  --url 'https://你的站点/不可猜测的路径/client-tun.json'
```

也可以在初次安装时指定 `--profile-url`，让安装结果和 `show` 命令显示导入链接：

```bash
sudo bash snell-reality-native.sh install \
  --server 你的VPS公网IP \
  --profile-url 'https://你的站点/不可猜测的路径/client-tun.json'
```

**指定 URL 只生成链接，不会上传文件、配置域名/证书、启动订阅服务器，也不会验证该 URL 上已有正确文件。** HTTPS 地址必须能实际下载所导出的 JSON，链接才能在支持此 URI 的客户端中使用；普通浏览器不一定注册该 URI。

配置包含连接凭据，HTTPS 地址及导入链接只交给可信设备。没有配置托管地址时，直接导入 JSON 文件即可，不需要额外的桥接程序。

## 从旧版切换

原生版使用独立的路径、系统账户、管理命令和服务名，不覆盖此前 Xray + 官方 Snell 版本。

如果旧版已在默认端口运行，先停止旧服务，再安装原生版：

```bash
sudo snell-reality stop
sudo bash snell-reality-native.sh install --server 你的VPS公网IP
```

切换时会生成新凭据，请重新导入原生版导出的客户端配置。原生版安装失败时，旧版文件仍在，可运行 `sudo snell-reality start` 恢复旧服务。

如需保留旧服务并行验证，为原生版同时选择不同的公网端口和回环端口，例如 `--port 8443 --snell-port 23457`，并放行新的 TCP 入口。

旧版 Xray 26.11.9 与 sing-box 1.14.4 组合存在 REALITY 握手兼容限制。原生版两端使用 sing-box 1.14.4，已验证无需额外桥接。旧版的独立说明见 [Xray 桥接方案](docs/legacy-xray.md)。

## 管理

```bash
sudo snell-reality-native show
sudo snell-reality-native check
sudo snell-reality-native status
sudo snell-reality-native restart
sudo snell-reality-native stop
sudo snell-reality-native start
sudo snell-reality-native logs
sudo snell-reality-native upgrade
sudo snell-reality-native uninstall
```

`upgrade` 升级到当前脚本固定的 sing-box 版本，保留原生版已有连接参数；重复执行 `install` 不重置配置。安装参数只用于首次安装。卸载可加 `--yes`，只移除原生版专用文件、服务与账户。

- 配置：`/etc/snell-reality-native/server.json`
- 安装状态和私钥：`/etc/snell-reality-native/state.json`，权限 600
- 客户端导出目录：`/etc/snell-reality-native/clients/`，目录 700、文件 600；不导出 REALITY 私钥
- 程序：`/usr/local/lib/snell-reality-native/sing-box`
- 服务：`snell-reality-native.service`

## 验证范围

2026-11-17，Linux amd64，sing-box 1.14.4：

- 真实运行一份服务端和一份客户端，传输并逐字节校验 1,121,000 字节 TCP 数据，并再次复用连接请求。
- 通过同一通道验证 32 / 1200 / 4096 字节 UDP 数据报。
- 错误 REALITY short ID 无法取得后端内容；普通外层 VLESS 连接不能绕过固定 Snell 后端。
- 服务端、mixed 与 TUN 的生成配置均通过核心 `check`。
- Bash / ShellCheck、输入校验、导入 URL 编码、私钥隔离、权限检查通过。
- 模拟 systemctl / userdel 的安装失败、升级失败及恢复失败测试通过。
- systemd 单元通过用户验证模式的语法与程序路径检查。

未在你的 VPS 上部署，未测试真实公网链路、arm64 执行、图形客户端导入和操作系统的 TUN 接管。公网仍需安装后从自己的客户端验证。amd64 / arm64 的固定下载摘要已对照官方 GitHub Release asset digest。

开发验证：

```bash
bash -n snell-reality-native.sh
shellcheck -x --source-path=SCRIPTDIR snell-reality-native.sh tests/rollback_native.sh
bash tests/rollback_native.sh
python3 tests/verify_native.py --sing-box /path/to/sing-box
```

`tests/verify_native.py` 复用 `tests/verify.py` 中的本地网络测试工具；测试不安装系统服务、不监听公网、不使用真实密钥。

## 官方依据

- [Snell 入站，since 1.14.0](https://github.com/SagerNet/sing-box/blob/v1.14.4/docs/configuration/inbound/snell.md)
- [Snell 出站](https://sing-box.sagernet.org/configuration/outbound/snell/)
- [Dial Fields：detour](https://sing-box.sagernet.org/configuration/shared/dial/)
- [sing-box 1.14.4 官方发布](https://github.com/SagerNet/sing-box/releases/tag/v1.14.4)
- [官方远程配置导入链接生成与解析](https://github.com/SagerNet/sing-box/blob/v1.14.4/experimental/libbox/remote_profile.go)
