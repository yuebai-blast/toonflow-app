# 仅运行后端：node / yarn 版本统一由 mise.toml 锁定（单一来源，避免多处维护）
FROM debian:bookworm-slim

WORKDIR /app

# 安装 mise 及其运行所需基础工具，并把 mise 与 shims 加入 PATH
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates git \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://mise.run | sh
ENV PATH="/root/.local/bin:/root/.local/share/mise/shims:${PATH}"
# 容器内非交互运行，预先信任本仓库配置，避免 mise 提示未受信任
ENV MISE_TRUSTED_CONFIG_PATHS=/app

# 先只拷贝工具链定义，按 mise.toml 装好 node/yarn（利用 Docker 层缓存）
COPY mise.toml ./
RUN mise install

# 国内镜像源，加速依赖安装（作用于 mise 提供的 npm/yarn）
RUN npm config set registry https://registry.npmmirror.com/ \
    && yarn config set registry https://registry.npmmirror.com/

# 拷贝其余源码后安装依赖
COPY . .

# 容器只跑后端：安装前剥离 Electron 相关依赖，避免下载桌面端二进制
RUN node -e "const fs=require('fs');const pkg=JSON.parse(fs.readFileSync('package.json','utf8'));for(const section of ['dependencies','devDependencies']){if(!pkg[section]) continue;for(const name of ['custom-electron-titlebar','electron','electron-builder','electron-rebuild','electronmon']) delete pkg[section][name];}fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2)+'\n');" \
    && mise run install --frozen-lockfile \
    && yarn cache clean

ENV NODE_ENV=dev
ENV PORT=10588

EXPOSE 10588

CMD ["mise", "run", "dev"]
