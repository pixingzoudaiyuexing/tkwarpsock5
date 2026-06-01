# tkwarpsock5

给 `wyx2685/v2node` 节点准备的 TikTok WARP SOCKS5 分流辅助脚本。

它会在节点 VPS 本机创建一个只监听 `127.0.0.1` 的 WARP SOCKS5 出口，然后生成 v2board/v2node 面板可直接粘贴的 TikTok 路由配置。最终效果是：TikTok 域名走 WARP，其他流量继续走节点原生出口。

已在 `v2node v0.4.0`、Xray `26.4.25`、`anytls/vless` 节点上实测：入站协议不影响这个用法，因为这里配置的是 Xray 出站 outbound。

## 一键安装

在节点 VPS 上执行：

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

# 只重新生成 v2board/v2node 路由文件，不重新安装 WARP
bash tkwarpsock5.sh --route-only

# 卸载本脚本创建的服务和配置
bash tkwarpsock5.sh --uninstall
```

## 输出文件

```text
/etc/tkwarpsock5/config.env
/etc/tkwarpsock5/tiktok-domains.txt
/etc/tkwarpsock5/v2board-match.txt
/etc/tkwarpsock5/outbound-socks.json
/etc/tkwarpsock5/v2node-route.json
/etc/tkwarpsock5/xray-routing-example.json
/var/log/tkwarpsock5.log
```

如果服务器上存在 `/etc/v2node`，脚本也会同步一份到：

```text
/etc/v2node/tkwarpsock5/
```

这只是给你复制粘贴用。v2node 的路由来自 v2board 面板 API，不会自动读取 `/etc/v2node/tkwarpsock5/*.json`。

## v2board 路由添加方法

进入 v2board 管理后台，打开“创建路由”。

备注：

```text
TikTok WARP
```

匹配值填写 `/etc/tkwarpsock5/v2board-match.txt` 的内容：

```text
domain:muscdn.com
domain:musical.ly
domain:sgpstatp.com
domain:snssdk.com
domain:tik-tokapi.com
domain:tiktok.com
domain:tiktokcdn.com
domain:tiktokv.com
domain:byteoversea.com
domain:ibytedtos.com
domain:ibyteimg.com
domain:ipstatp.com
domain:ttwstatic.com
domain:bytefcdn-oversea.com
domain:ttlivecdn.com
domain:tiktokcdn-us.com
domain:tiktokv.us
domain:p16-tiktokcdn-com.akamaized.net
```

动作选择：

```text
指定出站服务器(域名目标)
```

Xray 出站配置填写 `/etc/tkwarpsock5/outbound-socks.json` 的内容：

```json
{
  "tag": "tiktok-warp",
  "protocol": "socks",
  "settings": {
    "address": "127.0.0.1",
    "port": 40000
  }
}
```

保存后，到节点编辑页的“路由组”里选择 `TikTok WARP`，提交保存。

最后在节点 VPS 上重启 v2node：

```bash
systemctl restart v2node
```

也可以等待 v2node 自动拉取面板配置。

## 为什么 anytls 节点也支持

`anytls`、`vless`、`vmess` 这些是入站协议。这里添加的是 Xray 出站 outbound 和域名路由：

```text
用户 -> anytls/vless 入站 -> 命中 TikTok 域名 -> socks 出站 127.0.0.1:40000 -> WARP
```

因此节点入站协议不影响这条 TikTok 分流规则。

参考：

- [Xray Routing RuleObject](https://xtls.github.io/config/routing.html#ruleobject)
- [Xray OutboundObject](https://xtls.github.io/config/outbound.html)
- [Xray Socks 出站](https://xtls.github.io/config/outbounds/socks.html)

## 验证

确认 SOCKS5 监听：

```bash
ss -lntup | grep 40000
```

确认 WARP 出口：

```bash
curl --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace
```

正常情况下会看到：

```text
warp=on
```

确认 v2node 已拉到路由：

```bash
API_HOST=$(jq -r '.Nodes[0].ApiHost' /etc/v2node/config.json)
NODE_ID=$(jq -r '.Nodes[0].NodeID' /etc/v2node/config.json)
API_KEY=$(jq -r '.Nodes[0].ApiKey' /etc/v2node/config.json)

curl -fsSL "$API_HOST/api/v2/server/config?node_id=$NODE_ID&node_type=v2node&token=$API_KEY" \
  | jq '.routes'
```

确认主机默认出口没有被 WARP 接管：

```bash
curl https://ifconfig.co
```

## 工作方式

脚本优先使用 Cloudflare 官方 WARP Client 的 proxy 模式，这样不会修改整机默认路由。若官方 Client 不可用，会降级使用 `wireproxy` 创建本地 SOCKS5。

本脚本不自动登录面板、不写数据库。它只负责节点本机 WARP SOCKS5 出口和面板路由片段生成。

## 适用范围

- Debian / Ubuntu / CentOS 系 VPS
- 已部署或准备部署 `wyx2685/v2node` 的节点
- 只想让 TikTok 走 WARP，不想整台服务器全局走 WARP 的场景
