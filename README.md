# 原生 sing-box：Snell v6 unsafe-raw + REALITY

**VPS 使用 sing-box 1.14.4，支持 sing-box 客户端及 Exclave 0.17.68。** sing-box 从 1.14.0 起原生支持 Snell 入站与出站；客户端无需额外运行 Xray 桥接程序。

**v2.2 自动检测公网 IP，默认输出 Exclave 离线导入串，完整包含 Snell v6 + REALITY。无需域名、证书或订阅服务，默认只需放行 TCP 443。** HTTPS 远程配置下载改为可选功能，不再默认安装 Caddy 或申请 IP 证书。

客户端通过 `detour` 将 Snell v6 `unsafe-raw` 出站交给 VLESS + REALITY 出站。服务端先终止 REALITY，再把解出的 TCP 数据固定转发到同一进程中监听回环地址的 Snell 入站：

```text
客户端 sing-box
  应用 → Snell v6 unsafe-raw 出站 → detour: VLESS + REALITY 出站
                                       │ 公网加密 TCP
VPS sing-box                           ▼
  VLESS + REALITY 入站 → 固定转发 127.0.0.1:23456 → Snell v6 unsafe-raw 入站 → 目标
```

Snell 与 REALITY 通过两个出站串联。sing-box 客户端使用 `detour`，Exclave 导出使用其核心支持的 `proxySettings`，两者连接同一份服务端配置。

## 安装

支持 Debian 11+ / Ubuntu 22.04+，amd64 / arm64，运行中的 systemd。在 VPS 上执行，自动检测公网 IPv4，失败时尝试 IPv6：

```bash
curl -fL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/mutsuki14/snell-v6-reality/main/snell-reality-native.sh \
  -o snell-reality-native.sh && \
sudo bash snell-reality-native.sh install
```

如果已经下载或上传了脚本，直接执行：

```bash
sudo bash snell-reality-native.sh install --server 你的VPS公网IP
```

需要指定地址时使用 `--server 你的VPS公网IP`。NAT VPS 或设置了 HTTP 代理时请显式指定公网地址，并确保代理入口端口能转发到本机。使用域名时应直接解析到 VPS。

默认参数：

| 参数 | 默认 | 用途 |
| --- | --- | --- |
| `--port` | `443` | REALITY TCP 入口 |
| `--sni` | `www.cloudflare.com` | REALITY 目标，目标端口固定 443 |
| `--listen` | `0.0.0.0` | IPv6 地址自动选择 `::`；使用域名的 IPv6 部署请显式指定 |
| `--snell-port` | `23456` | Snell 的 VPS 回环端口 |
| `--socks-port` | `1080` | 客户端 mixed 本地代理端口 |
| `--with-share` | 关闭 | 额外安装 HTTPS 远程配置下载服务，通常不需要 |
| `--share-port` | `8443` | HTTPS 配置下载端口 |
| `--share-ip` | 服务器 IP | IP 证书和配置下载使用的公网 IPv4 / IPv6 |
| `--no-share` | 默认行为 | 不创建 HTTPS 分享服务；兼容旧版命令 |
| `--profile-url` | 空 | 使用自备 HTTPS 配置地址，跳过本机分享服务 |

例如：

```bash
sudo bash snell-reality-native.sh install \
  --server 你的VPS公网IP --port 9443 --sni www.cloudflare.com
```

脚本会检查端口占用、下载摘要、目标站点的证书/TLS 1.3/h2，生成随机 PSK、UUID、REALITY 密钥和 short ID，安装非 root systemd 服务，并导出客户端配置及 Exclave 离线导入串。代理部署失败会恢复本版原有文件及服务状态；若恢复本身失败，会保留备份并显示路径。

请在 VPS 防火墙和云安全组放行 REALITY TCP 入口。无需开放 `23456` 或入站 UDP；Snell UDP 流量通过同一个 TCP 隧道传输。脚本不修改防火墙，也不会停止占用端口的其他服务。

## Exclave 离线导入（默认）

目标是复制一段文本即可导入完整节点，不需要订阅地址。核对 Exclave **0.17.68** 源码后确认：它支持 Snell v6，但普通链接解析器没有 `snell://` 入口，也不支持将整个 Snell + REALITY 链路作为普通 Snell 节点 URI 导入。

本脚本使用 Exclave 自己支持的**剪贴板备份格式**：

```text
config?一整段Base64编码数据
```

这段文本内嵌完整配置和连接凭据，不会请求远程配置服务器，也不是 `snell://` 或可点击唤起客户端的 URI。导入后是一个包含完整链路的自定义配置，无需手动创建两个节点再组合代理链。

**已有安装**，下载新版后运行 `share`，无需重新安装代理：

```bash
curl -fL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/mutsuki14/snell-v6-reality/main/snell-reality-native.sh \
  -o snell-reality-native.sh && \
sudo bash snell-reality-native.sh share
```

1. 复制输出中以 `config?` 开头的完整一行，不要复制解释文字。
2. 在 Exclave 中选择**从剪贴板导入备份**，使用带“备份”的入口。
3. 选择新导入的 `Snell-v6-REALITY` 配置并连接。

普通“从剪贴板导入”只解析节点链接等格式，不能解析这份备份。以后执行 `sudo snell-reality-native share` 可再次显示导入串。脚本也保存了 `/etc/snell-reality-native/clients/exclave-import.txt`，可通过 Exclave 的“从文件导入备份”入口使用。

`client-exclave.json` 是 Exclave 自定义配置内容；不要把它当成 sing-box 配置，也不要通过普通节点列表解析入口导入，否则可能丢失代理链。Exclave 的自定义配置模式使用导出的 DNS 与路由设置。

离线导入串包含客户端凭据，但不包含服务端 REALITY 私钥。只交给需要使用的设备，不要提交到公开仓库。若之前运行过 v2.1 的 HTTPS 分享功能，可用 `sudo snell-reality-native share-off` 关闭下载服务；不会使已导入的代理凭据失效。

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

## 可选：HTTPS 远程配置导入

这个功能供需要远程更新完整 sing-box 配置的客户端使用，**Exclave 离线导入不需要它**。显式运行 `sudo snell-reality-native https-share`，或首次安装加 `--with-share`，才会安装独立的 Caddy 2.11.9。IP 证书签发成功后显示两种地址：

```text
https://你的公网IP:8443/随机访问令牌/client-tun.json
sing-box://import-remote-profile?url=经过编码的上述HTTPS地址#Snell-REALITY
```

支持该 URI 的 sing-box 客户端可一次导入完整配置。支持从 URL 导入完整配置的客户端也可使用第一个地址；使用文件导入时直接下载 JSON。桌面 mixed 配置可将地址末尾的 `client-tun.json` 换成 `client-mixed.json`。普通 `snell://` 或 `vless://` 节点链接无法完整表达这里的两层协议及 `detour` 关系。

后续使用：

```bash
sudo snell-reality-native show        # 再次显示配置地址和导入链接
sudo snell-reality-native https-share # 检查证书、同步配置并重试显示远程链接
sudo snell-reality-native share-logs  # 查看签发 / 续期日志
sudo snell-reality-native share-off   # 关闭下载服务，代理仍可使用
```

TCP 80 用于 HTTP-01 证书验证，必须可从公网访问；默认 TCP 8443 用于配置下载。若 8443 已占用，首次启用时加 `--share-port 9443`；若 80 已被其他服务占用，请用现有 HTTPS 托管方式或暂不启用分享。不要修改 REALITY 的 443 端口来申请分享证书。

Let's Encrypt 的 IP 证书使用 `shortlived` 配置，有效期约 160 小时。Caddy 会自动续期，需要保持服务运行和 TCP 80 可达。脚本验证证书信任及本机 HTTPS 下载内容后才记录并显示新链接；本机验证不能证明云安全组允许外部客户端下载。如果提示 HTTPS 尚未就绪，放行端口并检查日志后重新执行 `https-share`，已启动的签发服务会继续重试。分享失败不影响代理或离线导入。

分享使用 192 位随机路径，只提供两份客户端 JSON，禁止目录浏览，不提供服务端配置或 REALITY 私钥。链接及下载内容含代理连接凭据，只交给需要使用的设备，勿提交到公开仓库。`share-off` 会移除本机证书和下载服务；已导入的代理凭据仍有效。重新启用将生成新的分享路径，需要更新远程配置地址。

### 使用自备 HTTPS 地址

如果已有配置托管服务，也可以仅生成官方支持的导入链接：

```text
sing-box://import-remote-profile?url=经过编码的HTTPS配置地址#Snell-REALITY
```

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

**自定义 `--profile-url` 和 `import-link` 只生成链接，不会上传文件或验证远程内容。** HTTPS 地址必须能实际下载所导出的 JSON，链接才能在支持此 URI 的客户端中使用；普通浏览器不一定注册该 URI。

## 从旧版切换

原生版使用独立的路径、系统账户、管理命令和服务名，不覆盖此前 Xray + 官方 Snell 版本。

如果旧版已在默认端口运行，先停止旧服务，再安装原生版：

```bash
sudo snell-reality stop
sudo bash snell-reality-native.sh install --server 你的VPS公网IP
```

切换时会生成新凭据，请重新导入原生版导出的客户端配置。原生版安装失败时，旧版文件仍在，可运行 `sudo snell-reality start` 恢复旧服务。

如需保留旧服务并行验证，为原生版同时选择不同的公网端口和回环端口，例如 `--port 9443 --snell-port 23457`，并放行新的 TCP 入口。

旧版 Xray 26.11.9 与 sing-box 1.14.4 组合存在 REALITY 握手兼容限制。原生版两端使用 sing-box 1.14.4，已验证无需额外桥接。旧版的独立说明见 [Xray 桥接方案](docs/legacy-xray.md)。

## 管理

```bash
sudo snell-reality-native show
sudo snell-reality-native share
sudo snell-reality-native check
sudo snell-reality-native status
sudo snell-reality-native restart
sudo snell-reality-native stop
sudo snell-reality-native start
sudo snell-reality-native logs
sudo snell-reality-native upgrade
sudo snell-reality-native uninstall
```

`share` 仅生成并显示 Exclave 离线导入串。`upgrade` 升级到当前脚本固定的 sing-box 版本，保留原生版已有连接参数，并同步已启用的 HTTPS 分享文件；重复执行 `install` 不重置代理配置。代理安装参数只用于首次安装，HTTPS 分享参数可用于 `https-share`。卸载可加 `--yes`，移除原生版及本机分享专用文件、服务与账户。

- 配置：`/etc/snell-reality-native/server.json`
- 安装状态和私钥：`/etc/snell-reality-native/state.json`，权限 600
- 客户端导出目录：`/etc/snell-reality-native/clients/`，目录 700、文件 600；不导出 REALITY 私钥
- Exclave 离线导入：`clients/exclave-import.txt`；对应自定义配置：`clients/client-exclave.json`
- 程序：`/usr/local/lib/snell-reality-native/sing-box`
- 服务：`snell-reality-native.service`
- 分享设置：`/etc/snell-reality-share/`；随机令牌保存在仅 root 可读的 `share.json`
- 分享程序：`/usr/local/lib/snell-reality-share/caddy`
- 分享文件及自动续期数据：`/var/lib/snell-reality-share/`，使用独立非 root 账户
- 分享服务：`snell-reality-share.service`

## 验证范围

2026-11-17，Linux amd64，sing-box 1.14.4：

- 真实运行一份服务端和一份客户端，传输并逐字节校验 1,121,000 字节 TCP 数据，并再次复用连接请求。
- 通过同一通道验证 32 / 1200 / 4096 字节 UDP 数据报。
- 错误 REALITY short ID 无法取得后端内容；普通外层 VLESS 连接不能绕过固定 Snell 后端。
- 服务端、mixed 与 TUN 的生成配置均通过核心 `check`。
- Bash / ShellCheck、输入校验、导入 URL 编码、私钥隔离、权限检查通过。
- 模拟 systemctl / userdel 的安装失败、升级失败及恢复失败测试通过。
- systemd 单元通过用户验证模式的语法与程序路径检查。
- Exclave 0.17.68 对应核心提交 `2fc8bc67ba7930e83a7873ee30d0ffc2fdb102a4` 与本服务端实际互通：1,121,000 字节 TCP、再次请求、32 / 1200 / 4096 字节 UDP、模拟 Android DNS 入口路由及错误 REALITY 凭据拒绝。
- 离线备份经 Exclave 使用的 Kryo 5.7.1 Java 库实际解码、逐字节重新编码验证；IPv6 和包含特殊字符的凭据正确保留，不含服务端私钥。
- Caddy 2.11.9 接受实际生成的 ACME / `shortlived` 配置；本地测试 CA 下的真实 IP HTTPS 下载通过，包括无 SNI 握手、令牌隔离、禁止私钥文件下载及拒绝不受信任证书。
- 分享启动失败清理、待签发状态保留、重试保留令牌及关闭分享后的代理配置保留通过模拟服务管理验证。

未在你的 VPS 上部署，未测试真实公网链路、实际公网 IP 证书签发/续期、arm64 执行、图形客户端导入和操作系统的 TUN 接管。公网仍需安装后从自己的客户端验证。amd64 / arm64 的固定下载摘要已对照官方 GitHub Release asset digest。

开发验证：

```bash
bash -n snell-reality-native.sh
shellcheck -x --source-path=SCRIPTDIR snell-reality-native.sh tests/rollback_native.sh tests/share_lifecycle.sh
bash tests/rollback_native.sh
bash tests/share_lifecycle.sh
python3 tests/verify_native.py --sing-box /path/to/sing-box
python3 tests/verify_share.py --caddy /path/to/caddy
python3 tests/verify_exclave.py --sing-box /path/to/sing-box \
  --exclave-core /path/to/exclave-core --kryo-jar /path/to/kryo-5.7.1.jar
```

Python 测试复用 `tests/verify.py` 中的本地网络测试工具；测试不安装系统服务、不监听公网、不使用真实部署凭据。分享测试仅在回环接口运行，临时测试 CA 只用于测试客户端，不修改系统证书信任。

Exclave 验证需要 Java 11+ 的源文件启动能力、官方 Kryo 5.7.1 JAR，以及按上述提交编译的 Exclave 核心（Go 1.27）。该测试验证导入格式及核心互通，不代替 Android 手机上的界面导入与 VPN 接管测试。

## 官方依据

- [Snell 入站，since 1.14.0](https://github.com/SagerNet/sing-box/blob/v1.14.4/docs/configuration/inbound/snell.md)
- [Snell 出站](https://sing-box.sagernet.org/configuration/outbound/snell/)
- [Dial Fields：detour](https://sing-box.sagernet.org/configuration/shared/dial/)
- [sing-box 1.14.4 官方发布](https://github.com/SagerNet/sing-box/releases/tag/v1.14.4)
- [官方远程配置导入链接生成与解析](https://github.com/SagerNet/sing-box/blob/v1.14.4/experimental/libbox/remote_profile.go)
- [Exclave 0.17.68：普通节点链接与备份解析入口](https://github.com/ExclaveNetwork/Exclave/blob/0.17.68/app/src/main/java/io/nekohasekai/sagernet/ktx/Formats.kt)
- [Exclave 备份编码格式](https://github.com/ExclaveNetwork/Exclave/blob/0.17.68/app/src/main/java/io/nekohasekai/sagernet/fmt/UniversalFmt.kt)
- [Exclave 自定义配置备份字段](https://github.com/ExclaveNetwork/Exclave/blob/0.17.68/app/src/main/java/io/nekohasekai/sagernet/fmt/internal/ConfigBean.java)
- [Exclave 剪贴板备份导入实现](https://github.com/ExclaveNetwork/Exclave/blob/0.17.68/app/src/main/java/io/nekohasekai/sagernet/ui/ConfigurationFragment.kt)
- [Let's Encrypt：IP 证书与短期证书正式可用](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability/)
- [Caddy 2.11.9 官方发布](https://github.com/caddyserver/caddy/releases/tag/v2.11.9)
- [Caddy ACME 配置：profile 与挑战方式](https://caddyserver.com/docs/json/apps/tls/automation/policies/issuers/acme/)
