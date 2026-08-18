# 软件工程 Skills 项目规则

- 每个 skill 是 `.claude/skills/<name>/` 下的**自包含目录**：`SKILL.md` + 该 skill 需要的 `templates/`、`specs/` 副本。安装 = 把 skill 目录整目录复制到用户的 skill 目录（如 `~/.qoder/skills/<name>/`），不依赖、不触碰任何本地工程。
- skill 目录内 `templates/` 的目录结构与模板生成的目标工程保持一致（`templates/scripts/deploy.sh` 对应目标工程的 `scripts/deploy.sh`，以此类推）。
- `SKILL.md` 是面向智能体的操作手册，不是面向用户的使用说明；通过 `/skill-name` 调用。
- **路径禁令**：SKILL.md 中禁止出现 `software-engineering-skills/...` 这类依赖仓库克隆的路径；所有资源引用一律相对本 skill 目录。skill 运行时不得读取安装目录之外的仓库文件。
- **共享副本同步规则**：以下文件存在多份副本，修改任一份必须同步其余副本，并用 `md5sum` 验证一致：
  - `templates/scripts/deploy.sh`、`templates/scripts/apply-ssl.sh`：new-deploy 与 new-java-project 各一份
  - `specs/deployment-common.md`：new-java-project 与 new-nginx-conf 各一份
- 修改任何模板文件后，检查对应 SKILL.md 的说明是否仍然准确，保持两者同步。
- 任何改动不得破坏安装闭环：`git clone` 仓库 → 复制 `.claude/skills/<name>/` → 删除克隆，安装后即可完整使用。
- 每次修改后，需要输出本次修改的功能清单，列出改动涉及的模块/文件及对应功能点。
