# LightOffice 部署指南 (Deployment Guide)

面向运维人员：在内网中部署 LightOffice 桌面编辑器所依赖的私有存储与协作后端。

所有示例均使用本仓库 `deploy/docker-compose.nextcloud.yml` 定义的固定地址，
可直接复制执行；如需改为贵司实际网段，请统一替换下表中的值。

| 组件 | 地址 | 说明 |
|---|---|---|
| Nextcloud（私有存储） | `http://10.0.7.10:8080` | 桌面客户端默认连接地址 |
| ONLYOFFICE Document Server（协同编辑） | `http://10.0.7.20` | 提供实时协同与冲突合并 |
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

```bash
cat > deploy/.env <<'EOF'
DB_ROOT_PASSWORD=change-me-root
DB_PASSWORD=change-me-db
NEXTCLOUD_ADMIN_USER=lightadmin
NEXTCLOUD_ADMIN_PASSWORD=change-me-admin
DOCSERVER_JWT_SECRET=change-me-jwt
EOF
chmod 600 deploy/.env
```

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
curl -sS -o /dev/null -w 'nextcloud status.php -> %{http_code}\n' http://10.0.7.10:8080/status.php
curl -sS -o /dev/null -w 'documentserver healthcheck -> %{http_code}\n' http://10.0.7.20/healthcheck
curl -sS http://10.0.7.10:8080/status.php | python3 -m json.tool
```

## 6. 安装并连接 ONLYOFFICE Nextcloud 应用

```bash
docker exec -u www-data lightoffice-nextcloud php occ app:install onlyoffice
docker exec -u www-data lightoffice-nextcloud php occ config:app:set onlyoffice DocumentServerUrl --value="http://10.0.7.20/"
docker exec -u www-data lightoffice-nextcloud php occ config:app:set onlyoffice DocumentServerInternalUrl --value="http://10.0.7.20/"
docker exec -u www-data lightoffice-nextcloud php occ config:app:set onlyoffice StorageUrl --value="http://10.0.7.10:8080/"
docker exec -u www-data lightoffice-nextcloud php occ config:app:set onlyoffice jwt_secret --value="$(grep DOCSERVER_JWT_SECRET deploy/.env | cut -d= -f2)"
```

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
