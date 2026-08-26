# sql/ 数据库文件目录

存放本服务数据库的备份与更新 SQL 文件。

## 目录约定

| 目录 | 用途 | 版本控制 |
|---|---|---|
| `backup/` | 数据库备份导出文件，命名建议 `<DB_NAME>-YYYYMMDD[-HHmm].dump`（pg_dump -Fc 自定义格式） | 整体被 .gitignore 忽略，不入库 |
| `update/` | 更新 SQL 脚本，命名建议 `YYYYMMDD-<简述>.sql`（如 `20260826-add-order-index.sql`） | 入库，版本化管理 |

## 注意事项

- 备份文件可能包含真实数据与敏感信息，禁止提交到版本库；大体积备份应存放在部署主机的备份目录或对象存储，不要放进代码仓库。
- 更新脚本按文件名日期顺序执行；在生产库执行前先做一次备份（`backup/`）。
- 备份示例：`pg_dump -Fc -h 127.0.0.1 -U <user> <DB_NAME> > sql/backup/<DB_NAME>-$(date +%Y%m%d).dump`
