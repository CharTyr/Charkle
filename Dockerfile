# syntax=docker/dockerfile:1

FROM node:26-slim AS builder
WORKDIR /app

COPY package.json package-lock.json* tsconfig.base.json ./
COPY packages/shared/package.json packages/shared/
COPY packages/server/package.json packages/server/
COPY packages/client/package.json packages/client/

RUN npm ci || npm install

COPY packages ./packages
COPY figma-plugin ./figma-plugin

RUN npm run build

FROM node:26-slim AS runner
WORKDIR /app

ENV NODE_ENV=production \
    PORT=3417 \
    HOST=0.0.0.0 \
    CHARKLE_DATA_DIR=/data

COPY package.json package-lock.json* ./
COPY packages/shared/package.json packages/shared/
COPY packages/server/package.json packages/server/
COPY packages/client/package.json packages/client/

RUN npm ci --omit=dev || npm install --omit=dev

COPY --from=builder /app/packages/shared/dist ./packages/shared/dist
COPY --from=builder /app/packages/server/dist ./packages/server/dist
COPY --from=builder /app/packages/client/dist ./packages/client/dist
COPY --from=builder /app/figma-plugin ./figma-plugin

RUN mkdir -p /data
VOLUME ["/data"]
EXPOSE 3417

CMD ["node", "packages/server/dist/index.js"]
