# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

Toonflow 是一款 AI 短剧/漫剧创作工具：把小说自动改编为剧本，再结合 AI 生成图片和视频。
本仓库是它的**后端 + Electron 桌面壳**（前端构建产物以静态站点形式放在 `data/web/`）。

代码主体是 TypeScript（CommonJS 目标），用 `@/*` 别名映射到 `src/*`（见 `tsconfig.json`）。

## 常用命令

| 命令 | 说明 |
| --- | --- |
| `yarn dev` | 纯后端开发模式（nodemon + tsx 直跑 `src/app.ts`），监听 `10588` 端口 |
| `yarn dev:gui` | 启动 Electron 桌面壳（`electronmon -r tsx scripts/main.ts`） |
| `yarn dev:gui-vite` | 同上，但前端从 `http://localhost:50188` 的 Vite dev server 加载（需另行启动前端） |
| `yarn lint` | 类型检查（`tsc --noEmit`），本项目没有 ESLint，这条就是“lint” |
| `yarn build` | 用 esbuild 打包：`src/app.ts → data/serve/app.js`，`scripts/main.ts → build/main.js` |
| `yarn start` | 以 prod 模式运行已打包的 `data/serve/app.js` |
| `yarn dist` / `dist:win` / `dist:mac` / `dist:linux` | 先 build 再用 electron-builder 出安装包 |
| `yarn pack` | 只打 `--dir`（不出安装包），用于本地验证 Electron 打包结果 |
| `yarn vendor2json` | 把 `data/vendor/*.ts` 供应商模板转成 JSON（见 `scripts/vendor2json.ts`） |
| `yarn debug:ai` | 启动 `@ai-sdk/devtools`，调试 Vercel AI SDK 的流式调用 |
| `yarn license` | 生成第三方依赖许可清单（`scripts/license.ts` → `NOTICES.txt`） |

- **没有测试框架**，不存在单测命令。
- Docker（见 `Dockerfile`）只跑后端：安装前会剥离 electron 相关依赖，最终 `yarn dev` 监听 10588。

## 运行形态与启动链路

存在两种运行环境，靠 `typeof process.versions.electron` 判断（见 `src/env.ts`、`src/utils/getPath.ts`）：

- **纯 Node（dev）**：默认 `NODE_ENV=dev`，数据目录是 `<cwd>/data`，`src/app.ts` 直接被执行并 `startServe()`。
- **Electron（prod）**：默认 `NODE_ENV=prod`，数据目录是 `app.getPath("userData")/data`。
  `scripts/main.ts` 是主进程入口：启动时把打包进 `resources/data` 的资源按版本号增量拷贝到 userData（`initializeData`），再用自定义模块解析路径加载 `data/serve/app.js`，最后创建无边框窗口。窗口控制（最小化/关闭/重启/打开外链等）通过自定义 `toonflow://` 协议处理，不走 IPC。

`src/app.ts` 是 Express 服务核心：注册 socket.io、挂载 `/oss`（图片支持 `?size=` 实时生成缩略图）、`/skills`、`/assets`、`/web` 静态资源，做 JWT 鉴权中间件，最后挂载路由。

### 数据目录（`data/`）

`data/` 既是仓库里的资源模板，也是运行期的数据根（prod 下会被增量拷贝到 userData）。关键子目录：

- `data/serve/`：`build` 产物 `app.js`（打包后的后端），`start` 跑的就是它。
- `data/web/`：前端静态站点构建产物，由 `/web` 挂载。
- `data/skills/*.md`：所有 Agent prompt（改这里即可调 prompt，无需改代码）。
- `data/vendor/*.ts`：模型供应商模板，运行期在 vm2 沙盒里热执行。
- `data/models/`、`data/modelPrompt/`：模型与提示词相关资源。
- `data/assets/`、`data/oss/`：静态资产与对象存储（图片支持 `/oss?size=` 实时缩略图）。
- 运行时还会生成 `db2.sqlite`（库文件）和 `version.txt`（版本守卫，决定是否增量拷贝资源）。

## 核心架构

### 文件路由（自动生成，勿手改 router.ts）
`src/routes/**/*.ts` 采用**文件即路由**约定，由 `src/core.ts`（`generateRouter`）扫描生成 `src/router.ts`，统一挂在 `/api` 前缀下。文件名 `[id]` → `:id`，`[...x]` → `*`，`index` → 根。
- 仅在 `NODE_ENV=dev` 时重新生成，且用 `// @routes-hash` 做内容哈希守卫，无变化不重写。
- `src/router.ts` 和 `src/types/database.d.ts` 都是**自动生成文件**，`nodemon.json` 已忽略它们以免触发重启循环。新增接口请加 `src/routes/` 下的文件，不要直接编辑 `router.ts`。

### `u` 工具聚合对象
`src/utils.ts` 默认导出对象 `u`，聚合了 `db / oss / Ai / vm / vendor / getPath / task / getPrompts` 等。全仓库统一用 `import u from "@/utils"` 然后 `u.db(...)`、`u.Ai...`，这是最常见的调用入口。

### 数据库（knex + sqlite）
`src/utils/db.ts`：knex + `better-sqlite3`，库文件是数据目录下的 `db2.sqlite`。模块加载时自动跑 `initDB`（`src/lib/initDB.ts`，建表/种子）和 `fixDB`（迁移/修补）。dev 环境下还会用 `@rmp135/sql-ts` 从真实库结构反向生成 `src/types/database.d.ts`（哈希守卫）。`u.db("表名")` 带类型提示（`DB` 接口）。
鉴权用 JWT，密钥取自 `o_setting` 表的 `tokenKey`，除 `/api/login/login` 外所有接口都要求 token。

### Agent 系统（AI 编排）
两个 Agent，结构对称：
- `src/agents/scriptAgent`：小说 → 故事骨架 / 改编策略 / 剧本。
- `src/agents/productionAgent`：剧本 → 资产派生、资产生成、导演规划、分镜。

通过 socket.io 命名空间驱动：`src/socket/index.ts` 注册 `/api/socket/productionAgent`、`/api/socket/scriptAgent`，实现在 `src/socket/routes/`。模式是**决策层 Agent + 子 Agent（tool 形式调用）+ 监督层 Agent**：决策 Agent 用工具调用各子 Agent，子 Agent 把结果以约定 XML 标签写入工作区。
- 所有 prompt 不写在代码里，而是从 `data/skills/*.md` 读取（如 `script_agent_decision.md`、`production_execution_storyboard_gen.md`）。
- 记忆系统在 `src/utils/agent/memory.ts`：RAG（向量检索）+ 历史摘要 + 近期对话三段拼接。
- 流式输出经 `consumeFullStream` 解析 reasoning/text/error 块，回推给前端。

### AI 模型抽象与 Vendor 沙盒
- `src/utils/ai.ts`：定义 `AiType`（如 `scriptAgent:decisionAgent`），每个 key 通过 `o_agentDeploy` 表映射到具体模型。`o_setting.agentUseMode` 区分简易（`0`，按主 Agent 取配置）/高级（`1`，按完整 key 取配置）两种部署模式。基于 Vercel AI SDK（`ai` 包 + `@ai-sdk/*` 各家 provider）。
- **Vendor（模型供应商）以 TS 代码形式存储和热执行**：模板在 `data/vendor/*.ts`，运行期代码存数据目录的 `vendor/` 下，由 `src/utils/vm.ts`（vm2 沙盒）执行，沙盒里注入了 `createOpenAI / createAnthropic / createGoogleGenerativeAI` 等 SDK 工厂以及图片处理、轮询等辅助函数。`src/utils/vendor.ts` 负责读写/合并模型列表。这套机制让供应商接入逻辑可在运行时配置而无需重新打包。

## 约定与注意事项

- 所有路径必须经 `u.getPath()` 解析，它内置了防目录逃逸校验（`isPathInside`）。
- 改动 `data/skills/*.md` 即可调 prompt，无需改代码。
- 修改了路由或 DB 结构后，在 dev 模式跑一次让 `router.ts` / `database.d.ts` 自动重新生成，再提交。
