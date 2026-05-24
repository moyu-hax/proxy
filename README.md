## proxy Hy和Reality
```
curl -fsSL https://raw.githubusercontent.com/moyu-hax/proxy/refs/heads/main/proxy.sh -o proxy.sh && chmod +x proxy.sh && ./proxy.sh
```
## proxy2.sh
```
curl -fsSL https://raw.githubusercontent.com/moyu-hax/proxy/refs/heads/main/proxy2.sh -o proxy2.sh && chmod +x proxy2.sh && ./proxy2.sh
```
## swap.sh
```
curl -fsSL https://raw.githubusercontent.com/moyu-hax/proxy/refs/heads/main/swap.sh -o swap.sh && chmod +x swap.sh && ./swap.sh
```
## frp.sh
```
curl -fsSL https://raw.githubusercontent.com/moyu-hax/proxy/refs/heads/main/frp.sh -o frp.sh && chmod +x frp.sh && ./frp.sh
```
## mtp.sh
指定端口运行，不保存脚本文件：
```
PORT=56743 bash <(curl -Ls https://raw.githubusercontent.com/moyu-hax/proxy/refs/heads/main/mtp.sh)
```
指定端口和 FakeTLS 域名运行：
```
PORT=56743 FAKETLS_DOMAIN=example.com bash <(curl -Ls https://raw.githubusercontent.com/moyu-hax/proxy/refs/heads/main/mtp.sh)
```
Alpine 如果没有 bash，先安装：
```
apk add --no-cache bash
```
下载脚本文件后运行：
```
curl -fsSL https://raw.githubusercontent.com/moyu-hax/proxy/refs/heads/main/mtp.sh -o mtp.sh && chmod +x mtp.sh && ./mtp.sh
```
