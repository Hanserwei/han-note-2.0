# 本地中间件（Podman Compose）

根目录的 `podman-compose.yml` 只负责运行 Hannote 所需的 10 个中间件，并保留内存限制、健康检查和数据卷。建表、插件、namespace、索引和 bucket 均由开发者在首次部署时手工初始化。

## 首次部署

### 1. 宿主机参数

```bash
sudo sysctl -w vm.max_map_count=262144
sudo sysctl -w vm.overcommit_memory=1
```

### 2. 准备 Redis Roaring 模块

Redis Stack 自带 RedisBloom，但不包含 `redis-roaring`。首次部署执行一次：

```bash
podman volume create hannote_redis_modules
podman run --rm --network host --memory 512m --cpus 1 \
  -e REDIS_ROARING_VERSION=v1.7.4 \
  -v hannote_redis_modules:/modules \
  -v "$PWD/deploy/local/redis/build-roaring.sh:/init/build-roaring.sh:ro,Z" \
  docker.io/library/debian:bookworm-slim \
  /bin/sh /init/build-roaring.sh
```

### 3. 安装 Elasticsearch IK 插件

```bash
podman volume create hannote_elasticsearch_plugins
podman run --rm --user 1000:0 --memory 256m \
  -e ES_JAVA_OPTS="-Xms64m -Xmx128m" \
  -v hannote_elasticsearch_plugins:/usr/share/elasticsearch/plugins:U \
  --entrypoint /bin/sh \
  docker.elastic.co/elasticsearch/elasticsearch:9.4.3 \
  -c 'bin/elasticsearch-plugin install --batch https://get.infini.cloud/elasticsearch/analysis-ik/9.4.3'
```

### 4. 启动中间件

若 PowerJob Worker 不在中间件宿主机上，先把 Server 的 LAN 地址传给 Compose，确保 Server 向 Worker 发布可达地址：

```bash
export POWERJOB_EXTERNAL_ADDRESS=<中间件服务器IP>
podman-compose -f podman-compose.yml up -d
podman-compose -f podman-compose.yml ps
```

PowerJob Server 固定使用 Compose 网络地址 `10.90.20.10`，避免容器重建后 `app_info.current_server` 指向失效的动态地址。若只在同一台机器上联调，可不设置 `POWERJOB_EXTERNAL_ADDRESS`，默认使用 `127.0.0.1`。

### 5. 初始化业务数据

以下命令只需要在空数据卷上执行一次：

```bash
# Hannote PostgreSQL 表和种子数据
podman-compose -f podman-compose.yml exec postgres \
  psql -U hannote -d hannote -f /schema/init.sql

# PowerJob 5.1.2 表结构；导入完成后重启 Server
podman-compose -f podman-compose.yml exec powerjob-mysql sh -c \
  'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" powerjob-daily < /schema/powerjob.sql'
podman-compose -f podman-compose.yml restart powerjob-server

# ScyllaDB keyspace 和正文表（Scylla 仅监听容器网络 IP，不能在容器内使用 127.0.0.1）
podman-compose -f podman-compose.yml exec scylla sh -c \
  "node_ip=\$(hostname -i | cut -d' ' -f1); cqlsh \"\$node_ip\" 9042 \
  -f /schema/create-keyspace.cql"
podman-compose -f podman-compose.yml exec scylla sh -c \
  "node_ip=\$(hostname -i | cut -d' ' -f1); cqlsh \"\$node_ip\" 9042 \
  -k hannote -f /schema/note_content.cql"
podman-compose -f podman-compose.yml exec scylla sh -c \
  "node_ip=\$(hostname -i | cut -d' ' -f1); cqlsh \"\$node_ip\" 9042 \
  -k hannote -f /schema/comment_content.cql"

# Elasticsearch note/user 索引
ES_URL=http://127.0.0.1:9200 ./scripts/es-index/create-indices.sh
```

另外在控制台完成两项操作：

- Nacos `http://<服务器IP>:8080`：创建 namespace `hannote`。
- RustFS `http://<服务器IP>:9001`：创建 bucket `hannote`。

PowerJob 的应用和任务按 [PowerJob 配置指南](../../docs/powerjob-data-align-console-setup.md) 创建。若客户端不在中间件服务器上，还需在 `deploy/local/rocketmq/broker.conf` 中添加 `brokerIP1=<服务器IP>`。

## 日常使用

```bash
# 启动
podman-compose -f podman-compose.yml up -d

# 停止并保留数据
podman-compose -f podman-compose.yml down

# 删除所有数据卷（不可恢复）
podman-compose -f podman-compose.yml down -v
```

## 连接信息

| 中间件 | 默认端口 | 本地默认凭据/说明 |
|---|---:|---|
| Nacos Console / Server | `8080` / `8848` | Server 3.1.1；本地关闭鉴权 |
| PostgreSQL | `5432` | `hannote` / `hannote`，数据库 `hannote` |
| Redis | `6379` | 密码 `hannote-redis` |
| RocketMQ | `9876` / `10911` | NameServer / Broker |
| Elasticsearch | `9200` | 无鉴权 |
| ScyllaDB | `9042` | datacenter `datacenter1` |
| RustFS | `9000` / `9001` | S3 / Console；`hannoteadmin` / `hannote-local-secret` |
| PowerJob MySQL | `3306` | `root` / `powerjob-local` |
| PowerJob Server | `7700` | 5.1.2 首次启动无默认控制台用户，需在登录页注册 |

默认密码可通过 `POSTGRES_USER`、`POSTGRES_PASSWORD`、`REDIS_PASSWORD`、`RUSTFS_ACCESS_KEY`、`RUSTFS_SECRET_KEY`、`POWERJOB_MYSQL_PASSWORD` 环境变量覆盖。远程 Worker 还应设置 `POWERJOB_EXTERNAL_ADDRESS`。

## 内存限制

| 服务 | 容器上限 | 进程内部限制 |
|---|---:|---|
| PostgreSQL | 384 MiB | `shared_buffers=64MB`，最多 40 连接 |
| Redis Stack | 384 MiB | `maxmemory=256mb` |
| Nacos | 640 MiB | Java heap 128–256 MiB |
| RocketMQ NameServer | 256 MiB | Java heap 128 MiB |
| RocketMQ Broker | 768 MiB | Java heap 384 MiB，Direct Memory 128 MiB |
| Elasticsearch | 1 GiB | Java heap 512 MiB |
| ScyllaDB | 1 GiB | 单核，内部 memory 512 MiB |
| RustFS | 256 MiB | 容器硬限制 |
| PowerJob MySQL | 512 MiB | InnoDB buffer pool 64 MiB，最多 40 连接 |
| PowerJob Server | 1 GiB | Java heap 256–512 MiB |

常驻服务硬上限合计约 6.125 GiB；这是上限之和，不是预留内存。
