# 软件工程 Skills 项目规则

- `specs/` 目录是跨项目通用的部署规范文档。新增共享规范统一放在这里，不要和具体工程的规范混在一起。
- `templates/` 目录是可复用的文件模板。目录结构与模板生成的目标工程保持一致（`templates/scripts/deploy.sh` 对应目标工程的 `scripts/deploy.sh`，以此类推）。
- `.claude/skills/` 目录包含 Claude Code skill 定义文件，通过 `/skill-name` 调用。每个 skill 文件是面向 Claude 的操作手册，不是面向用户的使用说明。
- 修改任何模板文件后，检查对应 skill 文件的说明是否仍然准确，保持两者同步。
- 每次修改后，需要输出本次修改的功能清单，列出改动涉及的模块/文件及对应功能点。
