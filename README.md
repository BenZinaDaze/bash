# nq-route.sh — VPS 回程路由测试（NodeQuality 精简版）

从 [NodeQuality](https://github.com/LloydAsp/NodeQuality) 测评脚本中剥离出的**回程路由测试**部分，做成单文件脚本：不下载临时系统、不 chroot、不装依赖包、不向任何服务器上传数据。

```bash
bash <(curl -sL <你的托管地址>)        # 或直接 scp 上去运行
```

## 它测什么

对 VPS 到国内三网（电信 / 联通 / 移动）POP 节点做 TCP 80 端口的回程路由追踪，并自动判定骨干路由类型：

| 路由类型 | 含义 |
|---|---|
| `163` | 电信普通骨干（AS4134，走 202.97 段） |
| `CN2GT` | 电信 CN2 GT（Global Transit，进出混合 163） |
| `CN2GIA` | 电信 CN2 GIA（Global Internet Access，全程 59.43） |
| `CTGGIA` | 电信 CTGNet GIA（AS23764，CN2 升级网） |
| `4837` | 联通普通骨干（AS4837） |
| `9929` | 联通 CUII 商务骨干（AS9929） |
| `10099` | 联通 CUII（AS10099 出口） |
| `CMI` | 移动 CMI 国际骨干（AS58453 / AS9808） |
| `CMIN2` | 移动 CMIN2（AS58807） |
| `CERNET` / `CSTNET` | 教育网 / 科技网 |
| `Hidden` | 入网点被隐藏（入口即最后一跳） |
| `NoData` | 追踪失败或无法识别 |

每条线路输出：**境外段 → 路由类型**、途径地理路径、AS 路径、逐跳明细（含跳合并、IP 掩码、延迟着色：绿 ≤150ms / 黄 ≤240ms / 红 >240ms）。

## 用法

```bash
bash nq-route.sh              # 默认: IPv4 + IPv6(可用时), 上海/北京/广东 三网
bash nq-route.sh -4           # 仅 IPv4
bash nq-route.sh -6           # 仅 IPv6
bash nq-route.sh -p gd        # 仅广东三网
bash nq-route.sh -p gd,zj     # 多省（逗号分隔）
bash nq-route.sh -t 6         # 限制并发线程数（默认按可用内存自动, 上限 18）
bash nq-route.sh -k           # 将 nexttrace 保留到 /usr/local/bin, 免下次下载
bash nq-route.sh --selftest   # 离线自测（不联网, 验证聚合/分类/输出逻辑）
```

`-p` 省份支持三种写法：代码（`gd`）、简称（`粤`）、名称（`广东` / `广东省`），大小写不敏感。全部省份代码见脚本内 `PROV` 表。

## 输出示例

```
  上海 电信    Cogent -> CN2GIA
地理路径：上海    自治系统路径：AS53667 -> AS1299 -> AS4809
 1     0.30ms  10.0.*.*      AS0
 2     1.10ms  23.105.*.*    AS53667
 3     0.90ms  198.51.*.*    AS1299
 4   130.11ms  59.43.*.*     AS4809      中国 上海 电信
```

## 依赖与兼容性

- **Linux**，bash 4.3+、`curl`、`timeout`（绝大多数发行版开箱即用）
- 建议 **root** 运行（nexttrace 需要原始套接字构造 TCP 探测包）
- 网络：需能访问 GitHub Releases 下载 nexttrace（约 10MB，仅首次；`-k` 可保留）
- 支持amd64 / arm64 / armv7 / 386
- 无需 mount/chroot，**OpenVZ、LXC 等 mount 受限容器也可运行**（原版 NodeQuality 在这类环境会失败）

## 与原版的差异

| | NodeQuality 原版 | 本脚本 |
|---|---|---|
| 功能 | 硬件 / IP / 网速 / 回程 | 仅回程 |
| 运行方式 | 下载 BenchOS 临时系统 + mount + chroot | 直接运行 |
| 环境侵入 | 需挂载 /proc /sys /dev | 无 |
| 结果上传 | 上传至 api.nodequality.com / upload.check.place | 不上传 |
| jq / bc 依赖 | 需要 | 不需要 |
| 默认目标 | 10 个（上海电信重复测 2 次） | 9 个（去重） |

回程判定逻辑（目标节点、TCP 80、`-q 8 --psize 1400`、59.43→CN2、CTGNet→AS23764、路由分类、跳合并、IP 掩码等）与原版逐函数一致，nexttrace 同样锁定 v1.3.7 以保证输出解析稳定。

## 常见问题

**Q: 提示需要 root？**
nexttrace 构造原始报文需要 `CAP_NET_RAW`，`sudo` 或直接用 root 账户运行。

**Q: nexttrace 下载慢 / 失败？**
脚本从 GitHub Releases 拉取，如网络不佳可手动下载对应架构的 [nexttrace v1.3.7](https://github.com/nxtrace/NTrace-core/releases/tag/v1.3.7) 放到 `PATH` 中（如 `/usr/local/bin/nexttrace`），脚本会自动复用。

**Q: 某条线路显示 NoData？**
多为该目标节点超时（已重试 10 次）或 nexttrace 地理库未返回 ASN。可单独重跑：`bash nq-route.sh -p 省份`。

**Q: 如何分发给别人用？**
托管到任意可直链的地址（如自己的服务器、GitHub Gist raw），然后 `bash <(curl -sL 地址)`。

## 致谢

- [LloydAsp/NodeQuality](https://github.com/LloydAsp/NodeQuality) — 原测评脚本
- [xykt/NetQuality](https://github.com/xykt/NetQuality) — 回程测试与路由判定逻辑来源（`Net.Check.Place`）
- [nxtrace/NTrace-core](https://github.com/nxtrace/NTrace-core) — nexttrace 路由追踪工具
