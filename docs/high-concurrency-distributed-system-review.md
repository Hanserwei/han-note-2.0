# Hannote 高并发分布式系统项目审阅报告

## 1. 审阅结论

这个项目已经不是“微服务空壳”，缓存、消息队列、搜索、计数、KV 存储、分布式 ID 等核心组件都有真实实现。

但如果目标是建设一个“仿小红书的高并发分布式系统”，目前最需要补充的不是继续拆分微服务，而是：

1. 先修复安全与数据一致性问题；
2. 补齐推荐流、内容治理、媒体处理和通知等产品闭环；
3. 建设限流、熔断、可观测性、部署、迁移、灾备等生产治理能力；
4. 最后通过集成测试、契约测试、压测和混沌测试证明系统能力。

本次审阅覆盖：

- 13 个 Maven 模块；
- 约 462 个 Java 文件；
- 21 个 SQL/CQL 脚本；
- 28 个 Java 测试类；
- 网关、认证、用户、笔记、评论、关系、计数、搜索、KV、OSS、分布式 ID、数据对齐等核心链路。

### 优先级说明

- **P0**：现有代码中可触发的安全或数据正确性问题，上线前应解决；
- **P1**：要成为“小红书式高并发系统”基本必须具备；
- **P2**：规模化、工程成熟度和作品完整度提升。

## 2. 当前已有的良好基础

在列出缺口之前，项目中以下设计值得保留：

- Caffeine L1 + Redis L2 二级缓存；
- 空值哨兵防缓存穿透，随机 TTL 防缓存雪崩；
- RocketMQ 顺序消息处理点赞、收藏、关注等有序操作；
- 笔记正文发布使用 RocketMQ 事务消息协调 PostgreSQL 和 ScyllaDB；
- 评论服务具备 MQ 发送重试、失败表和 PowerJob 补偿重发；
- 评论、点赞、收藏、关注等核心表有唯一索引或幂等 Upsert；
- 计数服务具有削峰聚合设计；
- data-align 使用 PowerJob MapReduce 对计数进行定时纠偏；
- Elasticsearch 文档可以从 PostgreSQL 重建；
- ScyllaDB 用于存储笔记和评论正文；
- CoSId 使用 Redis 号段链模式生成趋势递增 ID；
- 部分消费者具备批量处理、顺序消费、限速和优雅关闭机制。

这些能力说明当前系统已经具备较好的分布式实践基础。后续应优先统一可靠性模型，而不是推翻现有架构。

---

## 3. P0：建议优先修复的现存问题

### 3.1 敏感信息会直接写入日志

[操作日志切面](../hannote-framework/hannote-spring-boot-starter-biz-operationlog/src/main/java/com/hanserwei/framework/biz/operationlog/aspect/ApiOperationLogAspect.java)会完整记录请求参数和响应；[认证接口](../hannote-auth/src/main/java/com/hanserwei/auth/controller/AuthController.java)又标注了该切面，因此以下信息都可能写入日志：

- 明文密码；
- 短信验证码；
- Authorization 请求头；
- 登录成功返回的 JWT；
- 修改密码请求中的新密码。

[验证码服务](../hannote-auth/src/main/java/com/hanserwei/auth/service/impl/VerificationCodeServiceImpl.java)还直接打印手机号和完整验证码。

#### 建议

- 认证接口禁止记录请求和响应正文；
- 增加统一、递归的日志脱敏器；
- 对 `password`、`newPassword`、`code`、`Authorization`、`token`、Cookie、Secret 等字段强制脱敏；
- 日志只保留接口、耗时、状态码、业务错误码和 traceId；
- 如果这些日志已经进入共享环境，应清理历史日志并评估 Token 吊销、密钥轮换和密码重置。

### 3.2 “内网 RPC”接口实际上可通过公网网关调用

网关把整个 `/user/**` 都转发给用户服务，[角色规则](../hannote-gateway/src/main/java/com/hanserwei/gateway/auth/PathAuthorizationRules.java)还是空的。

[用户 Controller](../hannote-user/hannote-user-biz/src/main/java/com/hanserwei/user/controller/UserController.java)同时包含公共接口和“仅内网 RPC”接口，包括：

- `/user/register`；
- `/user/findByPhone`；
- `/user/password/update`；
- `/user/findById`；
- `/user/findByIds`。

其中 `findByPhone` 还会返回 BCrypt 密文和角色。任何普通登录用户都可能经 `/user/user/findByPhone` 调用该内部接口。

#### 建议

- 网关改为外部接口显式白名单，不再按整个服务路径暴露；
- 内网接口使用独立 Controller、路径、端口或服务；
- 服务间使用 mTLS、SPIFFE、内部 JWT 或其他 workload identity；
- 下游服务不能只信任 `userId` 请求头；
- 网关应删除客户端传入的身份头，再写入经过认证的身份；
- 配合 Kubernetes NetworkPolicy、安全组或私有网络，阻止业务服务被直接访问；
- 认证服务不应通过一个可外部路由的 DTO 获取密码 Hash，可以改成窄范围的内部密码校验接口。

### 3.3 “仅自己可见”存在隐私泄漏路径

[修改可见性逻辑](../hannote-note/hannote-note-biz/src/main/java/com/hanserwei/note/service/impl/NoteServiceImpl.java)只删除笔记详情缓存，没有清理作者主页的已发布笔记列表缓存。

同时，[点赞、收藏、评论使用的查询](../hannote-note/hannote-note-biz/src/main/resources/mapper/NoteDOMapper.xml)只检查 `status=1`，没有检查 `visible` 和当前访问者。

可能造成：

- 私密笔记卡片继续出现在作者主页缓存中；
- 知道笔记 ID 的其他用户仍可点赞；
- 知道笔记 ID 的其他用户仍可收藏；
- 知道笔记 ID 的其他用户仍可评论；
- 搜索索引删除消息失败时，私密笔记仍可能出现在搜索结果中；
- 跨实例 L1 缓存失效失败时，旧公开数据可能继续被读取。

#### 建议

- 建立统一的 `canView/canInteract(noteId, actorId)` 权限查询；
- 详情、列表、搜索、点赞、收藏、评论统一复用该权限判断；
- 可见性变化时同时删除详情缓存和主页列表缓存；
- 在事务提交后发送可靠的、带版本号的缓存失效和搜索删除事件；
- 将单向的“仅自己可见”接口改为通用可见性状态转换接口；
- 为隐私状态变化增加专门的端到端测试。

### 3.4 被禁用账号仍然可以重新登录

[用户表](../docs/sql/t_user.sql)已经有 `status` 字段，但认证 DTO 不返回状态，[登录流程](../hannote-auth/src/main/java/com/hanserwei/auth/service/impl/AuthServiceImpl.java)也没有校验账号是否禁用或删除。

当前 JWT 默认有效期为 30 天，账号禁用、角色变更或密码修改后，旧 Token 仍可能继续使用。

#### 建议

- 认证契约返回并强制检查账号状态、删除状态和角色状态；
- 增加用户 `tokenVersion/sessionVersion`；
- 禁用账号、修改密码、修改角色时递增版本并使旧会话失效；
- 使用短期 Access Token + 可轮换 Refresh Token；
- 增加 `iss`、`aud`、`jti`、`kid` 和 token type；
- 长期建议使用非对称签名、JWKS 和 KMS/Vault 管理密钥。

### 3.5 点赞、收藏存在 Redis 成功但 MQ 永久丢失的问题

[点赞和收藏流程](../hannote-note/hannote-note-biz/src/main/java/com/hanserwei/note/service/impl/NoteServiceImpl.java)先修改 Redis Bitmap/ZSet，再异步发送 RocketMQ。

如果 MQ 发送失败：

1. Redis 已经标记用户点赞；
2. HTTP 接口已经返回成功；
3. 数据库没有对应记录；
4. 客户端重试会被 Redis 判断为“已经点赞”；
5. Bitmap 过期并从数据库重建后，点赞状态又会消失。

收藏、取消点赞、取消收藏存在同类问题。

#### 建议

- 使用事务 Outbox；
- 或者先持久化带幂等键的互动命令，再异步更新 Redis 投影；
- 事件至少包含 `eventId`、`userId`、`noteId`、操作类型和业务版本；
- API 只在命令或消息被可靠接收后返回成功；
- 如果必须先写 Redis，应在 MQ 失败时执行补偿 Lua，并提供可靠重试记录。

### 3.6 关注、取关存在相同的双写问题

[关系服务](../hannote-user-relation/hannote-user-relation-biz/src/main/java/com/hanserwei/relation/service/impl/RelationServiceImpl.java)先修改 Redis ZSet，再同步发送 MQ。

如果 Redis 修改成功但 MQ 发送失败：

- HTTP 请求报错；
- Redis 已经变更；
- PostgreSQL 没有变更；
- 重试又会得到“已关注”或“未关注”；
- Redis 过期并从 PostgreSQL 重建后，关系再次反转。

#### 建议

- 以 PostgreSQL 关系状态 + Outbox 作为权威数据；
- Redis 只作为查询投影；
- 或先记录持久化操作意图，再执行 Redis Lua；
- 重试接口应能识别未完成操作并继续发布，不能仅凭缓存状态拒绝。

### 3.7 计数服务在 MQ 确认前没有完成持久化

[点赞计数消费者](../hannote-count/hannote-count-biz/src/main/java/com/hanserwei/count/consumer/CountNoteLikeConsumer.java)收到消息后只将消息放入进程内无界 Reactor 缓冲，监听方法随即返回，相当于 RocketMQ 源消息已经 ACK。

风险包括：

- 进程在一秒聚合窗口内崩溃，消息永久丢失；
- `*2DBTopic` 异步发送失败只记录日志；
- DB 消费者捕获异常并正常返回时，失败消息也会被确认；
- `onBackpressureBuffer()` 无界增长可能导致 OOM；
- 重复消息会导致计数重复累加；
- 评论事件虽然有 `eventId`，但计数侧没有使用它去重。

收藏、粉丝、关注、评论计数消费者有相似模式。

#### 建议

- 使用有界缓冲和明确的背压策略；
- 在源消息 ACK 前把事件或聚合批次写入 Inbox/Outbox；
- DB 失败时抛出异常，让 RocketMQ 重试；
- 所有计数事件增加 `eventId`；
- Inbox 插入和计数增量必须在同一个数据库事务中；
- 建立 DLQ、积压监控、失败告警和人工/自动重放工具。

### 3.8 数据对齐服务有三类事件订阅已经断开

[data-align MQ 常量](../hannote-data-align/src/main/java/com/hanserwei/dataalign/constant/MQConstants.java)仍订阅：

- `CountNoteLikeTopic`；
- `CountNoteCollectTopic`；
- `CountFollowingTopic`。

但计数服务已经改为直接消费：

- `LikeUnlikeTopic`；
- `CollectUnCollectTopic`；
- `FollowUnfollowTopic`。

仓库中没有前三个旧 Topic 的实际生产者。因此点赞、收藏、关注的计数漂移目前不能靠夜间任务修复。

另一个问题是部分对齐 SQL 使用普通 `UPDATE`。如果实时计数事件完全丢失，计数表中还没有对应行，普通 `UPDATE` 影响零行，仍然无法修复。

#### 建议

- data-align 使用独立 Consumer Group 直接订阅真实源 Topic；
- 根据 Tag 解析 Follow/Unfollow、Like/Unlike 等操作；
- 对齐写入统一使用 `INSERT ... ON CONFLICT DO UPDATE`；
- 只有在权威计数覆盖、Redis 刷新和 ES 刷新全部成功后，才能删除待对齐记录；
- 正确性账本不应依赖 Bloom Filter 的“可能存在”结果跳过精确写入。

### 3.9 笔记跨 PostgreSQL/ScyllaDB 更新不具备原子性

[笔记更新逻辑](../hannote-note/hannote-note-biz/src/main/java/com/hanserwei/note/service/impl/NoteServiceImpl.java)先更新 PG 事务中的元数据，再同步覆盖或删除 KV 正文。

如果 KV 成功后 PG 提交失败：

- PostgreSQL 元数据回滚；
- ScyllaDB 正文不会回滚；
- 旧元数据可能引用已经更新的正文；
- 删除正文操作可能造成已发布笔记引用不存在的内容。

#### 建议

- 正文使用不可变、版本化 UUID；
- 先写新正文版本；
- 在 PostgreSQL 事务中切换引用并写 Outbox；
- 提交后再异步删除旧正文；
- 定期扫描悬空内容和失效引用；
- 更新操作增加乐观锁版本，避免并发覆盖。

### 3.10 笔记状态变更缺少完整幂等状态机

当前删除更新条件只包含 ID 和作者，不要求旧状态必须是 `NORMAL`。重复删除同一篇笔记仍可能再次发送 `-1` 发布数事件。

事务消息发布也存在接口结果问题：本地事务可能返回 `ROLLBACK`，但发布服务仍可能无条件返回成功。

评论发布还存在“校验笔记正常后，笔记被删除，再异步落评论”的竞态。

#### 建议

- 所有状态变更使用“期望旧状态 + 新状态 + version”的条件更新；
- 删除使用 `WHERE status=NORMAL`；
- 只有真正发生状态迁移时才发布事件；
- 状态事件设置固定幂等 ID，例如 `noteId:deleted`；
- 事务消息返回 `ROLLBACK` 时接口返回失败，`UNKNOWN` 时返回 `PENDING`；
- 评论消费者落库前重新校验笔记状态或消费笔记状态投影。

### 3.11 缓存失效发生在事务提交前

笔记更新和删除在数据库事务提交前广播 L1 缓存失效。

可能出现：

1. 其他实例收到失效消息；
2. 立即回源数据库；
3. 此时事务尚未提交，因此读到旧数据；
4. 旧数据重新写入 L1；
5. 后续延迟双删只删除 Redis，不删除远端 L1；
6. 旧数据在 Caffeine 中继续存在约一小时。

用户资料更新也只删除 Redis，没有同步删除本机和其他实例的用户 L1 缓存。

#### 建议

- 事务提交后通过可靠 Outbox 发布失效事件；
- 事件包含实体版本号；
- L1、L2 都保存版本并拒绝旧版本覆盖新版本；
- 当前实例在更新成功后立即清理本机缓存；
- 跨实例缓存失效失败时可通过版本检查自愈。

### 3.12 请求约束与 RocketMQ 消息大小不一致

[发布笔记 DTO](../hannote-note/hannote-note-biz/src/main/java/com/hanserwei/note/model/vo/PublishNoteReqVO.java)几乎没有标题、正文、URL 长度约束，但[生产配置](../hannote-note/hannote-note-biz/src/main/resources/application-prod.yml)将 RocketMQ 最大消息设置为 4096 字节，同时完整正文会进入事务消息。

这会导致普通长正文也可能在 MQ 或数据库阶段失败，并且错误发生得过晚。

#### 建议

- DTO 长度与 PostgreSQL 字段、ScyllaDB 字段和 MQ 限制保持一致；
- 验证集合数量和集合元素长度；
- 验证 URL 协议、域名和格式；
- 网关和服务端都设置 JSON 请求体大小上限；
- 大正文先写入内容存储，消息中只传内容 ID 或版本引用。

---

## 4. P1：仿小红书最关键的业务能力

### 4.1 首页推荐流和关注流

目前唯一的多笔记接口是按作者查询主页笔记，[SQL](../hannote-note/hannote-note-biz/src/main/resources/mapper/NoteDOMapper.xml)也是按 `creatorId` 查询。系统没有真正的首页内容消费入口。

#### 建议分阶段建设

第一阶段：

- `/feed/following`：关注作者的时间流；
- `/feed/recommended`：近期公开内容 + 热度 + 时间衰减；
- 游标分页、曝光去重和已读过滤。

第二阶段：

- 采集曝光、点击、停留、完播、跳过、点赞、收藏、评论、关注、屏蔽等行为；
- 建立用户兴趣标签和内容标签；
- 多路召回：关注、协同过滤、相似内容、热门、同城、话题；
- 粗排、精排、重排；
- 多样性、作者打散、负反馈过滤和冷启动；
- AB 实验、CTR、停留时长、互动率和留存指标。

### 4.2 搜索、频道和话题发现入口

搜索服务已经实现，但网关没有 `/search/**` 路由；频道和话题表主要停留在初始化数据和发布校验层。

#### 建议

- 暴露受限流保护的搜索接口；
- 支持搜索建议、搜索历史和热搜榜；
- 增加频道列表、热门话题、话题详情和话题笔记流；
- 增加话题关注；
- 提供受 RBAC 保护的频道、话题管理接口；
- 搜索综合评分加入时间衰减、内容质量、负反馈和多样性。

### 4.3 内容审核、举报和管理后台

笔记状态已经定义“待审核、正常、删除、下架”，但发布时直接写 `NORMAL`；评论没有审核状态，也没有举报、申诉或处罚记录。

#### 建议

- 内容审核单；
- 用户举报单；
- 机器审核结果；
- 人工复核；
- 敏感词、涉政、色情、广告、诈骗等审核标签；
- 下架原因和创作者可见的拒绝原因；
- 用户处罚和申诉；
- 管理员 RBAC；
- 审计日志；
- 仅允许审核通过内容进入推荐流和搜索索引。

### 4.4 完整媒体处理链路

当前 OSS 主要负责把上传流写入对象存储，还不是真正的媒体平台。

#### 建议

- 预签名直传，减少应用服务器带宽压力；
- 分片上传和断点续传；
- 文件魔数和真实 MIME 检测；
- 图片解码、重编码和超大图片防护；
- 病毒扫描和隔离区；
- 视频转码、封面生成、时长和分辨率提取；
- 媒体处理状态机：`UPLOADING/PROCESSING/READY/FAILED`；
- CDN、WebP/AVIF、多尺寸缩略图；
- 对象存储私有 Bucket + 签名 URL；
- 用户存储配额和上传频率限制；
- 孤儿文件清理；
- 笔记只引用属于当前用户且状态为 `READY` 的媒体资产 ID。

### 4.5 消息通知中心

系统已经有关注、点赞、收藏、评论和回复事件，但没有通知表、未读状态或通知接口。

#### 建议

- 建立 Inbox/Notification 服务；
- 按接收者分区存储；
- 事件幂等去重；
- 点赞、收藏等通知聚合；
- 游标分页；
- 已读/未读状态；
- 未读数缓存；
- 删除、屏蔽、审核后的通知回收；
- 可选 WebSocket、SSE、APNs 或厂商 Push。

### 4.6 拉黑、屏蔽和私密账号

现有社交图只有关注和取关，缺少用户安全与隐私关系。

#### 建议

- 拉黑和取消拉黑；
- 关注申请和审批；
- 私密账号；
- 粉丝可见和互关可见；
- 屏蔽作者、屏蔽话题和“不感兴趣”；
- 拉黑时自动解除双方关注；
- 在主页、笔记、评论、关注、通知和推荐链路统一执行关系规则。

### 4.7 点赞列表、收藏夹和置顶功能闭环

点赞和收藏的 ZSet 已经维护，但没有对外的列表接口。

`topNote` 会写 `is_top`，主页查询却仍然只按 ID 降序，因此置顶操作看不到实际效果。

#### 建议

- 点赞历史列表；
- 收藏列表和多个收藏夹；
- 收藏夹公开、私密设置；
- 列表只返回当前仍可访问的笔记；
- 主页排序改为 `is_top DESC, id DESC`；
- 置顶变化后失效作者主页列表缓存。

### 4.8 创作者工作台

可以补充：

- 草稿；
- 预览；
- 定时发布；
- 恢复删除；
- 评论管理；
- 作品表现统计；
- 粉丝趋势；
- 内容诊断；
- 审核反馈；
- 违规记录和申诉状态。

### 4.9 客户端幂等和异步操作状态

发布笔记和发布评论虽然生成了 ID，但接口返回空成功。网络丢失响应后，客户端重试会生成新的 ID，造成重复内容。

#### 建议

- 支持 `Idempotency-Key`；
- 持久化 `(user, operation, key) -> resultId`；
- 保存请求 Payload Hash，防止同一个 Key 被不同请求复用；
- 重复请求返回第一次的资源 ID 和状态；
- 异步发布返回 `PENDING/PROCESSING/PUBLISHED/FAILED`；
- 提供状态查询和失败重试接口。

### 4.10 统一 BFF/聚合层

笔记详情页通常需要聚合：

- 笔记元数据；
- 正文；
- 作者信息；
- 点赞、收藏和评论计数；
- 当前用户互动状态；
- 当前用户与作者的关系；
- 评论预览；
- 媒体处理结果。

建议增加面向客户端的 BFF，统一超时预算、降级、字段裁剪、协议版本和缓存策略，避免客户端理解内部微服务边界。

---

## 5. P1：高并发和生产治理能力

### 5.1 网关流控与过载保护

当前网关路由主要只有 `StripPrefix`，缺少系统入口的资源保护。

#### 建议

- 按 IP、用户、设备和接口进行分布式限流；
- 全局在途请求并发上限；
- 请求体大小上限；
- 排队和超时上限；
- 区分 429 和 503；
- 热门接口单独配置配额；
- 登录和短信接口配置更严格的反滥用策略；
- Redis 连接池等待时间不能使用无限等待；
- 鉴权 Redis 需要高可用和故障策略。

短信接口还应增加：

- 原子 `SET NX EX` 冷却；
- 原子 `GETDEL` 或 Lua 一次性消费验证码；
- 手机号/IP/设备/账号/全局额度；
- 验证码和行为验证；
- 密码失败次数和账号锁定；
- 短信费用告警；
- 短信 Provider 超时和有界执行器。

### 5.2 RPC 超时、熔断、隔离和降级

[RPC Starter](../hannote-framework/hannote-spring-boot-starter-rpc/src/main/java/com/hanserwei/framework/rpc/config/LoadBalancedRestClientConfigurer.java)主要配置了负载均衡和身份透传，没有连接、读取、总超时、熔断和隔离。

#### 建议

- 为每个目标服务设置连接、读取和总超时；
- 使用统一 Timeout Budget；
- 按下游服务设置并发 Bulkhead；
- 使用熔断器；
- 只有幂等读请求才自动重试；
- 重试采用指数退避和 Jitter；
- ID、KV 等核心依赖失败时快速失败；
- 头像、计数等装饰数据失败时返回部分结果；
- 记录 RPC 延迟、错误率、熔断状态和饱和度。

### 5.3 限制虚拟线程带来的下游放大

note、user、relation、auth 多处使用每任务一个虚拟线程。虚拟线程降低线程成本，但不会限制：

- Socket 数量；
- DB 连接；
- Redis 请求；
- 堆内存；
- 下游服务并发；
- 第三方短信请求数。

建议在 RPC、缓存回源、短信和异步写入前增加 Semaphore、Bulkhead、有界队列和拒绝策略。

### 5.4 热 Key 与缓存击穿治理

现有随机 TTL 和空值哨兵值得保留，但热点内容在缓存失效时仍可能发生大量并发回源。

评论列表还存在“互动一次就删除整个热门评论 ZSet”的模式，爆款笔记可能形成持续失效、持续重建。

#### 建议

- Single-flight；
- 逻辑过期；
- stale-while-revalidate；
- 短时分布式锁；
- 热点数据预热；
- 缓存失效合并；
- 评论热度使用 `ZINCRBY/ZADD` 增量更新；
- 全量重建时写临时版本 Key，再原子切换；
- 热 Key 拆分和本地只读副本。

### 5.5 数据库超时、索引和游标分页

目前部分 Hikari 连接获取最长等待 60 秒，Redis 使用 `max-wait=-1ms`。依赖饱和时，大量虚拟线程会继续等待，形成延迟崩塌。

#### 建议

- 缩短连接池获取超时；
- PostgreSQL 配置 `statement_timeout`；
- 配置 `lock_timeout`、connect timeout 和 socket timeout；
- 按所有服务副本总量计算 DB 连接预算；
- 增加 `(creator_id, id DESC) WHERE visible=0 AND status=1` 笔记索引；
- 关注和粉丝增加 `(user_id, create_time DESC, id DESC)`；
- 粉丝和评论深分页改为稳定游标；
- 使用 `(create_time, id)` 解决相同时间戳的分页稳定性；
- 增加慢 SQL、锁等待和连接池饱和告警。

### 5.6 Elasticsearch 深分页、索引切换和高可用

当前搜索使用 `from + size`，页码没有最大值。全量索引脚本直接删除旧索引再重建，索引配置还是单分片、零副本。

#### 建议

- 使用 PIT + `search_after`；
- 限制最大翻页深度；
- 使用稳定排序字段和 ID Tie-breaker；
- 设置 ES 请求超时；
- 不需要精确总数时关闭精确 `track_total_hits`；
- 全量重建使用新索引 + Alias 原子切换；
- 生产环境配置副本；
- 定期快照和恢复演练；
- 文档增加业务版本，防止旧事件覆盖新投影。

### 5.7 ScyllaDB 热分区拆分

评论正文分区键是 `(note_id, year_month)`。爆款笔记一个月的全部评论正文都会落到同一分区和副本集合。

#### 建议

- 在分区键中加入由 `contentId` 计算的固定桶；
- 或使用更细的时间桶；
- 查询时并行访问少量确定桶；
- 监控分区大小、Compaction、P99 和热点节点；
- 保留当前批量请求数量限制。

### 5.8 基础组件高可用拓扑

当前配置形式基本都是单个 Redis、PostgreSQL、Elasticsearch 和 ScyllaDB 地址。

建议明确并落地：

- Redis Sentinel 或 Redis Cluster；
- PostgreSQL 主备、PITR、连接代理和只读副本；
- RocketMQ Broker 和 NameServer 集群；
- Nacos 集群；
- Elasticsearch 多节点、副本和快照；
- ScyllaDB 多节点和多个 Contact Point；
- 对象存储版本控制和跨地域复制；
- PowerJob Server 高可用；
- 定期故障切换测试。

如果生产环境变量指向 HA Proxy，也应把这一点写成明确的部署契约并做故障演练。

### 5.9 可观测性

仓库中目前没有完整的 Actuator、Micrometer、Prometheus、OpenTelemetry、链路上下文和 SLO 配置。

#### 建议

- readiness、liveness、startup 探针；
- HTTP、RPC、MQ、DB、Redis、ES、Scylla 指标；
- traceId 跨 HTTP 和 MQ 透传；
- 结构化 JSON stdout 日志；
- 统一字段脱敏；
- MQ 积压、DLQ、Outbox、Inbox 指标；
- 数据对齐漂移指标；
- 缓存命中率、回源率和热 Key；
- 连接池、线程/虚拟线程、队列和限流器饱和度；
- P50、P95、P99；
- 错误率和 SLO Burn Rate；
- Dashboard、告警负责人和故障处理 Runbook。

### 5.10 部署编排和容器安全

当前主要提供 Dockerfile，没有 Compose、Kubernetes、Helm 或 Kustomize；容器默认使用 root 用户，也没有健康检查。

#### 建议

- 提供 Helm 或 Kustomize；
- 使用不可变镜像 Digest；
- 非 root 用户；
- 只读根文件系统；
- 删除不需要的 Linux Capability；
- requests/limits；
- readiness/liveness/startup Probe；
- Graceful Shutdown；
- PDB；
- HPA；
- Topology Spread；
- NetworkPolicy；
- Ingress TLS；
- Secret Manager；
- 明确启用 `prod` Profile；
- 内部 PostgreSQL、Redis、Nacos、RocketMQ 等启用认证和 TLS。

### 5.11 数据库迁移和灾备

SQL 目前主要依赖人工执行，没有 Flyway 或 Liquibase。

#### 建议

- 每个数据服务维护独立、版本化迁移；
- 支持 Expand/Migrate/Contract 滚动升级；
- CI 测试从上一个生产 Schema 升级；
- Seed 数据和生产 Reference Data 分离；
- 迁移前备份；
- 迁移锁、失败处理和 Forward Fix 流程；
- PostgreSQL 配置 PITR；
- ScyllaDB 配置快照、Repair 和恢复；
- 对象存储开启版本和复制；
- Nacos 配置备份；
- 为每个数据源定义 RPO/RTO；
- 定期执行恢复演练并记录实际恢复时间。

---

## 6. P2：工程完整度

### 6.1 测试金字塔

目前全项目只有 28 个 Java 测试类：

- gateway 没有测试；
- search 没有测试；
- OSS 没有测试；
- user-relation 没有测试；
- note 只有少量枚举测试；
- 部分集成测试依赖手工准备的外部服务；
- 没有统一的 `src/test/resources` 测试环境。

#### 建议

- Testcontainers PostgreSQL/Redis/ScyllaDB；
- 可控的 RocketMQ/Elasticsearch 集成环境；
- 网关安全矩阵测试；
- Header 伪造和直接服务访问测试；
- JWT 过期、撤销、禁用账号和角色变化测试；
- Outbox/Inbox 测试；
- MQ 重复、乱序、重试和 DLQ 测试；
- 缓存一致性测试；
- 数据迁移测试；
- 注册、发布、更新、删除、互动、计数、搜索的端到端测试。

### 6.2 CI/CD 质量门禁

当前 Docker 构建全部使用 `-DskipTests`，主分支可以直接发布未测试镜像。

#### 建议

- PR 必须执行 `mvn verify`；
- 设置覆盖率门槛；
- 运行数据库迁移测试；
- CodeQL 或 Semgrep；
- Maven 依赖和 License 扫描；
- Secret 扫描；
- Trivy/Grype 镜像扫描；
- CycloneDX/SPDX SBOM；
- 镜像签名和 Provenance；
- GitHub Action 使用完整 Commit SHA 固定版本；
- 最小化 Workflow 权限；
- 测试通过的同一个镜像 Digest 在环境间晋级，不要重新构建发布产物。

### 6.3 OpenAPI、AsyncAPI 和兼容性管理

HTTP Interface 能提供编译期复用，但不能约束独立部署和 MQ 事件兼容性。

#### 建议

- 维护版本化 OpenAPI；
- 维护版本化 AsyncAPI；
- 定义向后和向前兼容规则；
- 为 DTO 和事件维护 Schema；
- CI 中执行 Provider/Consumer Contract Test；
- 对 Breaking Change 使用显式 API/Event 版本；
- 提供弃用周期和迁移文档。

### 6.4 容量、压测和混沌测试

仓库中目前没有 k6、Gatling、JMeter、Toxiproxy、Chaos Mesh 或类似工具。

#### 建议

- 先定义各接口预期 QPS、并发和数据规模；
- 定义延迟、错误率、积压和恢复时间目标；
- 压测登录、短信、推荐流、笔记详情、上传、评论和互动；
- 构造爆款笔记和热点作者；
- 测试 Redis、PG、MQ、ES、Scylla 延迟；
- 测试依赖部分失败；
- 测试 Retry Storm；
- 测试实例中断和优雅关闭；
- 测试 MQ 重复、乱序和积压恢复；
- 验证恢复过程中不会重复计数或丢失状态。

### 6.5 水平扩容时的全局限速

目前多个消费者使用进程内 Guava RateLimiter。实例数量增加后，总速率会按实例数线性放大，而 PostgreSQL 容量并不会同步增加。

#### 建议

- 限速按实际处理行数而不是消息数计费；
- 根据共享数据库总预算计算每实例额度；
- 配合消费者线程数、批量大小和实例数动态调整；
- 必要时使用分布式配额或中心化配置；
- 扩容前验证数据库总连接数和总写入 QPS。

### 6.6 日志和非关键高频操作优化

分布式 ID 服务为每个生成的 ID 写 INFO 日志，高 QPS 下日志本身可能成为开销。

#### 建议

- 单 ID 日志改为采样 DEBUG/TRACE；
- 使用指标记录 ID QPS、号段消耗和 Redis 申请延迟；
- 审核其他高频消费者中的逐消息 INFO 日志；
- 对大消息体日志做摘要和长度限制。

### 6.7 修正文档和未完成接口

当前存在一些文档和实现漂移：

- `RelationServiceImpl` 仍将粉丝列表的 `fansTotal/noteTotal` 固定为 0，但 count 服务已经存在；
- README 中列出的 `hannote-test-console` 实际不存在；
- 部分 DESIGN 描述的 Topic 已经与当前实现不一致；
- 个别注释仍描述“计数服务尚未建设”。

#### 建议

- 增加批量用户计数 RPC；
- 修复粉丝列表的计数字段；
- 清理 TODO 和过时注释；
- 自动生成服务接口和 Topic 清单；
- 在 CI 中检查文档引用和实际模块是否一致。

---

## 7. 建议实施顺序

### 第一阶段：安全和正确性

1. 删除认证敏感日志并统一脱敏；
2. 关闭公共网关对内部 RPC 的访问；
3. 修复私密笔记的缓存、搜索和互动权限；
4. 加入账号状态、Token 版本和会话失效；
5. 修复点赞、收藏、关注的 Redis/MQ 双写；
6. 修复计数服务 ACK 前不持久化的问题；
7. 修复 data-align 订阅断开；
8. 修复笔记跨 PG/KV 更新、重复删除和事务消息结果判断；
9. 补齐请求字段和消息大小约束。

### 第二阶段：内容产品闭环

1. 关注流和基础推荐流；
2. 搜索、频道和话题入口；
3. 内容审核、举报和后台；
4. 媒体资产和处理流水线；
5. 通知中心；
6. 拉黑、私密账号和可见性规则；
7. 点赞列表、收藏夹和置顶闭环；
8. 客户端幂等和异步状态查询。

### 第三阶段：生产治理

1. 网关限流和过载保护；
2. RPC 超时、熔断、隔离和降级；
3. 热 Key 和缓存击穿治理；
4. 数据库索引、连接预算和游标分页；
5. Elasticsearch 和 ScyllaDB 扩展治理；
6. 可观测性和 SLO；
7. Kubernetes/Helm 和容器安全；
8. 数据迁移、备份和灾备。

### 第四阶段：验证系统能力

1. 单元、集成、契约和端到端测试；
2. CI/CD 质量门禁；
3. OpenAPI/AsyncAPI；
4. 容量模型；
5. 压力测试；
6. 混沌和故障恢复测试；
7. 定期演练 DLQ、Outbox、数据对齐和灾备恢复。

---

## 8. 最终判断

当前 Hannote 已经具备一个较完整的内容社交微服务练习项目基础，尤其在以下方面有较好的实践：

- 多级缓存；
- RocketMQ 顺序消息和事务消息；
- Redis Lua；
- PostgreSQL 幂等约束；
- ScyllaDB 内容存储；
- Elasticsearch 搜索；
- CoSId 分布式 ID；
- PowerJob 数据对齐。

但在修复以下问题之前，不宜将其定义为已经具备生产级高并发能力：

- 内外网接口边界不安全；
- 认证敏感数据泄漏到日志；
- 私密内容权限不完整；
- Redis/MQ/DB 双写存在永久丢失窗口；
- 计数服务在持久化前确认源消息；
- 数据对齐的部分 Topic 已经断开；
- 缺少统一幂等事件和 Outbox/Inbox；
- 缺少限流、熔断、超时、观测、部署和灾备；
- 缺少首页推荐流、审核、媒体、通知等小红书核心产品闭环。

最合理的建设方向是：**先统一安全与可靠性底座，再建设推荐和内容产品能力，最后用生产治理与系统性测试证明高并发能力。**

## 9. 验证说明

本次为只读代码和配置审阅，没有修改项目源代码。

曾尝试执行：

```bash
mvn test -B
```

但当前运行环境没有安装 `mvn`，因此未能完成构建和测试验证。后续建议在具备 Maven 和所需依赖服务的环境中执行：

```bash
mvn verify -B
```

并结合 Testcontainers 或受控测试环境完成 PostgreSQL、Redis、RocketMQ、Elasticsearch 和 ScyllaDB 集成验证。
