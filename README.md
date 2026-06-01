# tkwarpsock5

给 `wyx2685/v2node` 节点准备的 TikTok WARP SOCKS5 分流辅助脚本。

它会在节点本机创建一个只监听 `127.0.0.1` 的 WARP SOCKS5 出口，然后生成 v2node 可用的 TikTok 域名路由片段。这样 TikTok 流量走 WARP，其他流量继续走节点原生出口。

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pixingzoudaiyuexing/tkwarpsock5/main/tkwarpsock5.sh)
```

默认 SOCKS5 地址：

```text
127.0.0.1:40000
```

如果端口被占用，脚本会自动尝试 `40001-40020`。

## 常用参数

```bash
# 指定 SOCKS5 端口
bash tkwarpsock5.sh --port 40001

# 添加额外 TikTok 域名
bash tkwarpsock5.sh --add-domain example.com

# 只重新生成 v2node 路由片段，不重新安装 WARP
bash tkwarpsock5.sh --route-only

# 卸载本脚本创建的服务和配置
bash tkwarpsock5.sh --uninstall
```

## 输出文件

```text
/etc/tkwarpsock5/config.env
/etc/tkwarpsock5/tiktok-domains.txt
/etc/tkwarpsock5/v2node-route.json
/var/log/tkwarpsock5.log
```

## v2node 路由配置

脚本会生成：

```bash
cat /etc/tkwarpsock5/v2node-route.json
```

示例：

```json
{
  "action": "route",
  "match": [
    "domain:muscdn.com",
    "domain:musical.ly",
    "domain:sgpstatp.com",
    "domain:snssdk.com",
    "domain:tik-tokapi.com",
    "domain:tiktok.com",
    "domain:tiktokcdn.com"
  ],
  "action_value": "{\"protocol\":\"socks\",\"tag\":\"tiktok-warp\",\"settings\":{\"servers\":[{\"address\":\"127.0.0.1\",\"port\":40000}]}}"
}
```

把这段路由填到面板里对应节点的路由配置中，然后重启 `v2node` 或等待它自动拉取最新节点配置。

> 本脚本不自动登录面板、不写数据库，只负责节点本机 WARP SOCKS5 出口和路由片段生成。

## 验证

确认 SOCKS5 监听：

```bash
ss -lntup | grep 40000
```

确认 WARP 出口：

```bash
curl --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace
```

正常情况下会看到类似：

```text
ip=104.x.x.x
colo=xxx
warp=on
```

确认主机默认出口没有被 WARP 接管：

```bash
curl https://ifconfig.co
```

## 工作方式

脚本优先使用 Cloudflare 官方 WARP Client 的 proxy 模式，这样不会修改整机默认路由。若官方 Client 不可用，会降级使用 `wireproxy` 创建本地 SOCKS5。

内置 TikTok 域名列表包括：

```text
muscdn.com
musical.ly
sgpstatp.com
snssdk.com
tik-tokapi.com
tiktok.com
tiktokcdn.com
tiktokv.com
byteoversea.com
ibytedtos.com
ibyteimg.com
ipstatp.com
p16-tiktokcdn-com.akamaized.net
```

## 适用范围

- Debian / Ubuntu / CentOS 系 VPS
- 已部署或准备部署 `wyx2685/v2node` 的节点
- 只想让 TikTok 走 WARP，不想整台服务器全局走 WARP 的场景

