# sql/ 数据库备份目录

只放一样东西：**数据库备份导出文件**。结构变更脚本不放这里，放
`deploy-conf/db/migrations/<服务>/`（约定与执行方式见那份目录的 `README.md`）。

| 内容 | 命名建议 | 版本控制 |
|---|---|---|
| `backup/` 下的备份导出 | `<DB_NAME>-YYYYMMDD[-HHmm].dump`（`pg_dump -Fc` 自定义格式） | 整体被 `.gitignore` 忽略，不入库 |

## 注意事项

- 备份文件包含真实数据与敏感信息，禁止提交到版本库；大体积备份应存放在部署主机的备份目录或对象存储，
  不要放进代码仓库。
- `deploy.sh --target db`（全量重建，不是增量升级）自己把 dump 落在 `runtime/db-sync-*/`，不经本目录；
  本目录放**人工备份**（改结构、跑大版本升级前先落一份）。
- 备份示例：

  ```bash
  ( set -a; . src/backend/<SERVICE_NAME>/.env; set +a
    PGPASSWORD="$DB_PASSWORD" pg_dump -Fc -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USERNAME" -d "$DB_NAME" \
        > sql/backup/$DB_NAME-$(date +%Y%m%d).dump )
  ```

- 恢复示例：`pg_restore --clean --if-exists -h 127.0.0.1 -U <user> -d <DB_NAME> <文件>.dump`
  （先确认目标库，`--clean` 会 DROP 已有对象）。
