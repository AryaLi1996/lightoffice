# LightOffice 部署指南 (Deployment Guide)

面向运维人员：在内网中部署 LightOffice 桌面编辑器所依赖的私有存储与协作后端。

所有示例均使用本仓库 `deploy/docker-compose.nextcloud.yml` 定义的固定地址，
可直接复制执行；如需改为贵司实际网段，请统一替换下表中的值。

| 组件 | 地址 | 说明 |
|---|---|---|
| Nextcloud（私有存储） | `https://10.0.7.10` | 桌面客户端默认连接地址（经 nginx 终结 TLS） |
| ONLYOFFICE Document Server（协同编辑） | `https://10.0.7.10:8443` | 提供实时协同与冲突合并 |
| MariaDB | `10.0.7.30:3306` | 仅内网可见，不对外发布端口 |
| 内网网段 | `10.0.7.0/24` | Docker bridge `lightoffice-intranet` |

> 说明：编排文件同时把 Nextcloud 发布到宿主机 `:8080`，便于冒烟测试；
> 生产环境如不需要，请删除该 `ports` 映射，仅保留 `10.0.7.0/24` 内网访问。

---

## 1. 前置检查

确认 Docker 与 Compose 插件可用，并确认 `10.0.7.0/24` 未被占用：

```bash
docker version --format 'Server {{.Server.Version}}'
docker compose version
ip route | grep -q '10\.0\.7\.' && echo "网段冲突，请修改 compose 中的 subnet" || echo "网段可用"
```

## 2. 配置凭据

不要使用编排文件中的默认口令。创建 `.env`（与 compose 文件同目录）：

编排文件把凭据声明为 `${VAR:?...}`：**没有 `.env` 就不会启动**。
这是刻意的——此前的 `${VAR:-默认值}` 意味着忘记配置的部署照样跑起来，
用的却是本仓库里公开的口令。

```bash
scripts/gen_env.sh          # 随机生成，重复运行会保留已有值
scripts/gen_env.sh --print  # 需要查看时
```

TLS 证书同样是启动前提：

```bash
scripts/gen_tls_cert.sh --host 10.0.7.10 --dns office.lightoffice.internal
```

> 自签证书只适用于实验环境：每台客户端都要被告知信任它，而这与信任攻击者的证书
> 无从区分。生产部署请用企业 CA 为**同一地址**签发证书替换
> `deploy/tls/{fullchain,privkey}.pem`，并通过既有渠道分发该 CA。

## 3. 启动协作栈

```bash
docker compose -f deploy/docker-compose.nextcloud.yml pull
docker compose -f deploy/docker-compose.nextcloud.yml up -d
docker compose -f deploy/docker-compose.nextcloud.yml ps
```

## 4. 等待服务就绪

三个服务都带 healthcheck；Document Server 首次启动需要数分钟初始化：

```bash
until [ "$(docker inspect -f '{{.State.Health.Status}}' lightoffice-nextcloud)" = healthy ]; do sleep 5; done; echo "Nextcloud ready"
until [ "$(docker inspect -f '{{.State.Health.Status}}' lightoffice-documentserver)" = healthy ]; do sleep 10; done; echo "Document Server ready"
```

## 5. 验证可达性

```bash
curl -sS --cacert deploy/tls/fullchain.pem -o /dev/null -w 'nextcloud status.php -> %{http_code}\n' https://10.0.7.10/status.php
curl -sS --cacert deploy/tls/fullchain.pem -o /dev/null -w 'documentserver healthcheck -> %{http_code}\n' https://10.0.7.10:8443/healthcheck
curl -sS --cacert deploy/tls/fullchain.pem https://10.0.7.10/status.php | python3 -m json.tool
```

## 6. 安装并连接 ONLYOFFICE Nextcloud 应用

```bash
docker exec -u www-data lightoffice-nextcloud php occ app:install onlyoffice
docker exec -u www-data lightoffice-nextcloud php occ config:app:set onlyoffice DocumentServerUrl --value="https://10.0.7.10:8443/"
docker exec -u www-data lightoffice-nextcloud php occ config:app:set onlyoffice DocumentServerInternalUrl --value="https://10.0.7.10:8443/"
docker exec -u www-data lightoffice-nextcloud php occ config:app:set onlyoffice StorageUrl --value="https://10.0.7.10/"
docker exec -u www-data lightoffice-nextcloud php occ config:app:set onlyoffice jwt_secret --value="$(grep '^DOCSERVER_JWT_SECRET=' deploy/.env | cut -d= -f2-)"
```

> **注意 `^` 与 `-f2-`**：`deploy/.env` 中还有一行注释提到 `DOCSERVER_JWT_SECRET`，
> 未加 `^` 锚定会同时匹配到注释行，把注释文本当成密钥写进去。
> 症状是编辑器报 `errorCode -20 / The document security token is not correctly formed`，
> 而错误信息完全不会提示密钥来源错了——这个坑我们实测踩过。

## 7. 确认信任域与文件锁

WebDAV 文件锁是多客户端并发编辑时返回 `423 Locked` 的前提：

```bash
docker exec -u www-data lightoffice-nextcloud php occ config:system:get trusted_domains
docker exec -u www-data lightoffice-nextcloud php occ app:enable files_lock
docker exec -u www-data lightoffice-nextcloud php occ config:list onlyoffice
```

## 8. 配置桌面客户端

客户端默认连接地址来自 `overlay/desktop-apps/common/loginpage/src/lightoffice-cloud.js`
与 `providers/lightoffice/config.json`。如需改到别的地址：

```bash
NEW_PORTAL="http://10.0.7.10:8080"   # 改成贵司实际地址
sed -i "s#http://10\.0\.7\.10:8080#${NEW_PORTAL}#g" overlay/desktop-apps/common/loginpage/src/lightoffice-cloud.js
sed -i "s#http://10\.0\.7\.10:8080#${NEW_PORTAL}#g" overlay/desktop-apps/common/loginpage/providers/lightoffice/config.json
scripts/apply_overlay.sh /home/user/onlyoffice-src
grep -r "defaultPortal\|defaultUrl" overlay/desktop-apps/common/loginpage/
```

## 9. 备份与恢复

```bash
docker exec lightoffice-db mysqldump -u root -p"$DB_ROOT_PASSWORD" nextcloud > backup-nextcloud-$(date +%F).sql
docker run --rm -v lightoffice_nextcloud_data:/data -v "$PWD":/backup alpine tar czf /backup/nextcloud-data-$(date +%F).tar.gz -C /data .
docker compose -f deploy/docker-compose.nextcloud.yml down
```

## 10. 日志与排障

```bash
docker compose -f deploy/docker-compose.nextcloud.yml logs --tail=100 nextcloud
docker compose -f deploy/docker-compose.nextcloud.yml logs --tail=100 documentserver
docker exec lightoffice-documentserver tail -n 100 /var/log/onlyoffice/documentserver/converter/out.log
docker exec -u www-data lightoffice-nextcloud php occ log:tail -n 50
```

常见问题：

- **客户端提示 “untrusted domain”** — 该地址不在 `trusted_domains` 中，
  见第 7 步；修改后需 `docker compose restart nextcloud`。
- **文档打开后一直转圈** — 通常是 JWT 不一致。Nextcloud 侧 `jwt_secret`
  必须与 Document Server 的 `JWT_SECRET` 完全相同（第 2、6 步）。
- **协同编辑不同步** — 确认 Document Server 的 WebSocket 未被反向代理拦截，
  代理需转发 `Upgrade` 与 `Connection` 头。

---

## AWS 部署（CloudFormation）

`deploy/aws/lightoffice-stack.yaml` 建立一台**固定私有地址**的协作主机。

### 为什么必须是固定地址

桌面客户端的默认门户地址是**编译期写进二进制的**，不是安装时配置的。
地址一旦变化，就要重新构建并重新分发**每一台**客户端。
所以该模板把实例钉在 `HostPrivateIp`（默认 `10.0.7.10`）——正是客户端里已经烘焙的地址。

### 两套地址空间（不要混淆）

| 用途 | 地址 | 谁能访问 |
|---|---|---|
| 客户端 → Nextcloud | `http://10.0.7.10:8080` | 企业内网（经 VPN / TGW / 对等连接） |
| 客户端 → Document Server | `http://10.0.7.10:8081` | 同上 |
| 容器之间 | `172.28.7.0/24` | **仅主机内部**，客户端永远不可达 |

容器网桥刻意**不用** `10.0.7.0/24`：在 AWS 主机上该网段属于 VPC 子网，
网桥若与之重叠会让主机对自己的地址产生双重路由，把流量打进黑洞。
`tests/unit/consistency.test.js` 会检测这种重叠并让构建失败。

### 部署

```bash
aws cloudformation deploy \
  --template-file deploy/aws/lightoffice-stack.yaml \
  --stack-name lightoffice-prod \
  --parameter-overrides CorporateCidr=10.50.0.0/16 AttachVpnGateway=yes \
  --capabilities CAPABILITY_IAM \
  --region ap-east-1
aws cloudformation describe-stacks --stack-name lightoffice-prod \
  --query 'Stacks[0].Outputs' --output table
```

`CorporateCidr` 是唯一必填参数，且被约束为 RFC1918——该主机存放公司文档，
安全组只对这个网段开放 8080/8081，实例位于私有子网且无公网地址。

### 管理与运维

主机通过 SSM Session Manager 访问，无需 SSH 密钥、无需堡垒机：

```bash
aws ssm start-session --target "$(aws cloudformation describe-stacks --stack-name lightoffice-prod --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)"
aws secretsmanager get-secret-value --secret-id lightoffice-prod/app --query SecretString --output text | jq .
```

凭据由 Secrets Manager 生成并在首次启动时补全后写回，
因此重建主机会复用同一套密钥——Document Server 的 JWT 两端必须一致，这点尤其重要。

文档与数据库放在**加密的 EBS 卷**上，其 `DeletionPolicy: Snapshot`：
删除 stack 不会静默销毁公司文档。

### 换成别的地址

若贵司网段与默认值冲突，务必在**构建客户端之前**改：

```bash
NEW_IP=192.168.30.10
sed -i "s#10\.0\.7\.10#${NEW_IP}#g" overlay/desktop-apps/common/loginpage/src/lightoffice-cloud.js
sed -i "s#10\.0\.7\.10#${NEW_IP}#g" overlay/desktop-apps/common/loginpage/providers/lightoffice/config.json
sed -i "s#Default: 10\.0\.7\.10#Default: ${NEW_IP}#" deploy/aws/lightoffice-stack.yaml
npm test    # 校验五处地址是否仍然一致
```

## Kubernetes 部署（可选）

如使用 K8s 而非 Compose：

```bash
kubectl create namespace lightoffice
kubectl -n lightoffice create secret generic lightoffice-secrets --from-env-file=deploy/.env
kubectl -n lightoffice apply -f deploy/docker-compose.nextcloud.yml
kubectl -n lightoffice rollout status deployment/nextcloud --timeout=300s
kubectl -n lightoffice get pods -o wide
```

> `kubectl apply` 不能直接消费 Compose 文件，请先用 `kompose convert -f deploy/docker-compose.nextcloud.yml`
> 生成清单后再 apply。上面的命令序列假设该转换已完成。
